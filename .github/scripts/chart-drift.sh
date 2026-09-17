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
#
# Needs helm and jq, and HTTPS access to the chart repositories. No cloud
# credentials: nothing here reads a live cluster. Uses a throwaway helm config
# directory, so it neither reads nor touches ~/.config/helm.

set -euo pipefail

chart_warn_behind="${CHART_WARN_BEHIND:-3}"
tailscale_warn_behind="${TAILSCALE_WARN_BEHIND:-0}"

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

for tool in helm jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "chart-drift: $tool is required but not on PATH" >&2
    exit 1
  }
done

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

while IFS='|' read -r _ _ repo _ _; do
  [ -n "$repo" ] || continue
  helm repo add --force-update "$(repo_alias "$repo")" "$repo" >/dev/null
done <<<"$pins"
helm repo update >/dev/null

attention=()

echo "## Helm chart pin drift"
echo
echo "Module-input chart pins against their repositories' stable releases (pre-releases ignored)."
echo
echo "| Chart | Pinned (variable) | Newest stable | Newer available |"
echo "| --- | --- | --- | --- |"

while IFS='|' read -r file variable repo chart warn_behind; do
  [ -n "$chart" ] || continue

  pin=$(hcl_default "$repo_root/$file" "$variable")
  name="$(repo_alias "$repo")/$chart"

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

  if [ -z "$position" ]; then
    note="**not a stable release**"
    attention+=("\`$chart\` pin $pin is not among the repository's stable releases (newest $newest). Set $variable in $file to a published version.")
  else
    behind=$((position - 1))
    note="$behind"
    if [ "$behind" -gt "$warn_behind" ]; then
      attention+=("\`$chart\` is $behind stable release(s) behind ($pin, newest $newest). Bump $variable in $file, reading the chart's release notes for breaking values changes.")
    fi
  fi

  echo "| \`$chart\` | $pin (\`$variable\`) | $newest | $note |"
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
