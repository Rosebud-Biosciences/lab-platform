#!/usr/bin/env bash
#
# Drift report for the Helm chart versions this module family pins as input
# defaults: for each, how many stable releases the pin trails the chart
# repository by.
#
# Dependabot's terraform ecosystem reads provider constraints and module
# sources; a chart version sitting in a variable default is invisible to it
# (see .github/dependabot.yml). Renovate could cover these with regex managers,
# but nothing here assumes it is set up. The pins are the module's promise to
# its users -- a fresh apply from defaults should not install last year's
# charts -- so this closes the gap without a bot.
#
# Only charts exposed as module inputs are checked. Versions written literally
# inside a helm_release (kube-prometheus-stack, argo, gpu-operator, ...) and
# charts pulled from OCI registries (no index.yaml to consult) are out of scope;
# bump those with the chart's own release notes to hand.
#
# Every version is shown with its release date, and the bump each finding asks
# for is to the newest stable release out at least CHART_COOLDOWN_DAYS: a
# release pushed from a hijacked chart repository is usually noticed and
# pulled within days, so nobody should adopt one that young. Thresholds still
# count every newer release, so a fresh one is reported rather than hidden.
# The dates are the index's `created` stamps, written by whoever publishes the
# repository -- a hijacker could backdate them -- so the delay catches the
# common case, not a careful attacker.
#
# Exit codes follow `tofu plan -detailed-exitcode`:
#   0  nothing needs attention
#   2  something does -- see the report's "Needs attention" section
#   1  (or anything else) the script itself failed
#
# Usage: chart-drift.sh
#   CHART_WARN_BEHIND      default threshold: flag a pin more than N stable
#                          releases behind (default 3)
#   TAILSCALE_WARN_BEHIND  threshold for the Tailscale operator chart (default
#                          0: any newer release, because that pin is the
#                          Tailscale version of every container on the tailnet,
#                          containers cannot self-update, and Tailscale ships
#                          CVE fixes as releases)
#   CHART_COOLDOWN_DAYS    how long a release must have been out before a
#                          finding names it as the version to bump to
#                          (default 7)
#
# Needs helm, jq and yq, and HTTPS access to the chart repositories. No cloud
# credentials: nothing here reads a live cluster. Uses a throwaway helm config
# directory, so it neither reads nor touches ~/.config/helm.

set -euo pipefail

chart_warn_behind="${CHART_WARN_BEHIND:-3}"
tailscale_warn_behind="${TAILSCALE_WARN_BEHIND:-0}"
cooldown_days="${CHART_COOLDOWN_DAYS:-7}"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# file | variable | chart repository | chart | warn_behind
# Keep in step with the helm_release blocks: the repository here must be the
# one the module installs from, or the comparison is against the wrong index.
pins="
aws/eks-platform/variables.tf|tailscale_operator_chart_version|https://pkgs.tailscale.com/helmcharts|tailscale-operator|$tailscale_warn_behind
aws/eks-platform/variables.tf|kuberay_operator_version|https://ray-project.github.io/kuberay-helm/|kuberay-operator|$chart_warn_behind
modules/workloads/variables.tf|ray_cluster_chart_version|https://ray-project.github.io/kuberay-helm/|ray-cluster|$chart_warn_behind
modules/workloads/variables.tf|jupyterhub_chart_version|https://hub.jupyter.org/helm-chart/|jupyterhub|$chart_warn_behind
modules/workloads/variables.tf|dagster_chart_version|https://dagster-io.github.io/helm|dagster|$chart_warn_behind
modules/workloads/variables.tf|mlflow_chart_version|https://community-charts.github.io/helm-charts|mlflow|$chart_warn_behind
"

for tool in helm jq yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "chart-drift: $tool is required but not on PATH" >&2
    exit 1
  }
done
# pip's `yq` (a jq wrapper) takes the same name and different expressions.
yq --version 2>&1 | grep -q mikefarah || {
  echo "chart-drift: yq must be mikefarah/yq v4 (brew install yq), not pip's yq" >&2
  exit 1
}

# Isolated helm state: the repo aliases below must not leak into, or collide
# with, whatever the operator has configured locally.
helm_home=$(mktemp -d)
trap 'rm -rf "$helm_home"' EXIT
export HELM_CACHE_HOME="$helm_home/cache" HELM_CONFIG_HOME="$helm_home/config" HELM_DATA_HOME="$helm_home/data"

# The quoted default of one variable block. Enough HCL parsing for a pin: the
# blocks in question are `variable "x" { ... default = "y" }`.
hcl_default() {
  local file="$1" name="$2" value
  value=$(awk -v name="$name" '$0 ~ "^variable \"" name "\"" {p=1} p && /^}/ {exit} p' "$file" |
    sed -n 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')
  if [ -z "$value" ]; then
    echo "chart-drift: no quoted default for variable \"$name\" in $file" >&2
    exit 1
  fi
  printf '%s' "$value"
}

# A repo alias helm will accept, derived from the URL so the same repository
# used by two pins is added once (--force-update makes re-adding harmless).
repo_alias() {
  printf '%s' "$1" | sed 's#^https\?://##; s#[^A-Za-z0-9]\{1,\}#-#g; s#-$##'
}

# One line per release of a chart, "version<TAB>epoch<TAB>YYYY-MM-DD", from
# the `created` stamps in the repository index helm downloaded. Publishers
# write the stamp with fractional seconds or a UTC offset, or not at all; a
# version without a parseable one is left out, i.e. its release date is
# unknown.
release_dates() {
  local repo_name="$1" chart="$2"
  CHART="$chart" yq -o=json '.entries[strenv(CHART)] // []' "$repo_cache/$repo_name-index.yaml" |
    jq -r '
      .[] | select(.created != null)
      | .version as $version
      | .created | tostring
      | capture("^(?<dt>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})([.][0-9]+)?(?<tz>Z|[+-][0-9]{2}:[0-9]{2})$")
      | ((.dt + "Z" | fromdateiso8601)
         - (if .tz == "Z" then 0
            else (if .tz[0:1] == "+" then 1 else -1 end)
                 * ((.tz[1:3] | tonumber) * 3600 + (.tz[4:6] | tonumber) * 60)
            end)) as $epoch
      | "\($version | tostring)\t\($epoch)\t\($epoch | strftime("%Y-%m-%d"))"'
}

# Whole days since a version's release, given release_dates output; empty when
# the date is unknown.
age_days() {
  local epoch
  epoch=$(awk -F'\t' -v v="$1" '$1 == v {print $2; exit}' <<<"$2")
  [ -z "$epoch" ] || echo $(((now - epoch) / 86400))
}

# "1.2.3, released 2026-10-01 (34 days ago)" for the report table.
describe() {
  local day
  day=$(awk -F'\t' -v v="$1" '$1 == v {print $3; exit}' <<<"$2")
  if [ -z "$day" ]; then
    printf '%s, release date unknown' "$1"
  else
    printf '%s, released %s (%s days ago)' "$1" "$day" "$(age_days "$1" "$2")"
  fi
}

while IFS='|' read -r _ _ repo _ _; do
  [ -n "$repo" ] || continue
  helm repo add --force-update "$(repo_alias "$repo")" "$repo" >/dev/null
done <<<"$pins"
helm repo update >/dev/null
repo_cache=$(helm env HELM_REPOSITORY_CACHE)
now=$(date +%s)

attention=()

echo "## Helm chart pin drift"
echo
echo "Module-input chart pins against their repositories' stable releases (pre-releases ignored)."
echo "Release dates are the repositories' own index stamps; a finding's bump target is the newest release out at least $cooldown_days days."
echo
echo "| Chart | Pinned | Newest stable | Newer available | Newest out $cooldown_days+ days |"
echo "| --- | --- | --- | --- | --- |"

while IFS='|' read -r file variable repo chart warn_behind; do
  [ -n "$chart" ] || continue

  pin=$(hcl_default "$repo_root/$file" "$variable")
  repo_name=$(repo_alias "$repo")
  name="$repo_name/$chart"
  dates=$(release_dates "$repo_name" "$chart")

  # `helm search repo --versions` lists stable versions newest-first (semver
  # order, pre-releases excluded without --devel); the exact-name select drops
  # sibling charts the substring search also matches (kuberay-operator vs
  # kuberay-apiserver, say).
  versions=$(helm search repo "$name" --versions -o json |
    jq -r --arg n "$name" '.[] | select(.name == $n) | .version')
  if [ -z "$versions" ]; then
    echo "chart-drift: chart $name not found in $repo" >&2
    exit 1
  fi
  newest=$(head -n1 <<<"$versions")
  # Position in the newest-first list == how many newer stable releases exist.
  position=$(grep -nxF "$pin" <<<"$versions" | head -n1 | cut -d: -f1 || true)

  # The newest stable release out at least $cooldown_days days, and its
  # position in the same list.
  settled="" settled_position=""
  i=0
  while read -r version; do
    i=$((i + 1))
    age=$(age_days "$version" "$dates")
    if [ -n "$age" ] && [ "$age" -ge "$cooldown_days" ]; then
      settled=$version settled_position=$i
      break
    fi
  done <<<"$versions"

  # A pin that is not a stable release can move to any of them.
  limit=${position:-$(($(wc -l <<<"$versions") + 1))}
  if [ -n "$settled" ] && [ "$settled_position" -lt "$limit" ]; then
    bump="Set $variable in $file to $settled (the newest release out $cooldown_days+ days), reading the chart's release notes for breaking values changes."
  else
    bump="No release to move to has been out $cooldown_days days yet; set $variable in $file once one has, or sooner only for a security fix you have checked."
  fi

  if [ -z "$position" ]; then
    note="**not a stable release**"
    attention+=("\`$chart\` pin $pin is not among the repository's stable releases; newest $(describe "$newest" "$dates"). $bump")
  else
    behind=$((position - 1))
    note="$behind"
    if [ "$behind" -gt "$warn_behind" ]; then
      attention+=("\`$chart\` is $behind stable release(s) behind: pinned $pin, newest $(describe "$newest" "$dates"). $bump")
    fi
  fi

  settled_note=${settled:-none yet}
  if [ -n "$settled" ] && [ -n "$position" ] && [ "$settled_position" -gt "$position" ]; then
    settled_note="$settled (older than the pin)"
  fi

  echo "| \`$chart\` | \`$variable\` = $(describe "$pin" "$dates") | $(describe "$newest" "$dates") | $note | $settled_note |"
done <<<"$pins"

echo
if [ "${#attention[@]}" -eq 0 ]; then
  echo "Nothing needs attention. Thresholds: more than $chart_warn_behind stable release(s) behind; more than $tailscale_warn_behind for the Tailscale operator chart."
  exit 0
fi

echo "### Needs attention"
echo
for item in "${attention[@]}"; do
  echo "- $item"
done
exit 2
