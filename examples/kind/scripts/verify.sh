#!/usr/bin/env bash
# Assert the workloads came up on the current kubectl context: every
# Deployment rolled out, the RayCluster reports ready, and each UI answers its
# health endpoint from inside the cluster. Exit non-zero on the first failure.
#
#   NAME_PREFIX   the workloads name_prefix (default empty)
#   WITH_JUPYTERHUB=1   also check the hub
set -euo pipefail

P="${NAME_PREFIX:-}"
TIMEOUT="${TIMEOUT:-10m}"

rollout() {
  echo "-- $1: deployments"
  local d
  for d in $(kubectl -n "$1" get deployments -o name); do
    kubectl -n "$1" rollout status "$d" --timeout="$TIMEOUT"
  done
}

rollout "${P}webapp"
rollout "${P}mlflow"
rollout "${P}dagster"

echo "-- ${P}ray: RayCluster ready"
kubectl -n "${P}ray" wait "raycluster/${P}ray-cluster" --for=jsonpath='{.status.state}'=ready --timeout="$TIMEOUT"

if [ "${WITH_JUPYTERHUB:-0}" = "1" ]; then
  rollout "${P}jupyterhub"
fi

# In-cluster HTTP checks: a throwaway curl pod per URL so no port-forwards are
# needed (and it works identically on CI runners).
probe() {
  local ns="$1" url="$2"
  echo "-- GET $url"
  kubectl -n "$ns" run "probe-$RANDOM" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.16.0 -- -sSf --max-time 20 "$url" >/dev/null
}

# Service names: the webapp Service carries webapp_app_name (unprefixed; its
# namespace is prefixed), Helm-derived services carry the prefixed release.
probe "${P}webapp"  "http://webapp.${P}webapp.svc.cluster.local/"
probe "${P}mlflow"  "http://${P}mlflow.${P}mlflow.svc.cluster.local/health"
probe "${P}dagster" "http://${P}dagster-dagster-webserver.${P}dagster.svc.cluster.local/server_info"

echo "== all workloads healthy"
