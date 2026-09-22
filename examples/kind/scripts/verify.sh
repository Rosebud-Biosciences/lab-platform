#!/usr/bin/env bash
# Assert the workloads came up on the current kubectl context: every
# Deployment rolled out, the RayCluster reports ready, each UI answers its
# health endpoint from inside the cluster, and -- auth mode "oidc" -- Dex
# issues tokens, every protected UI demands a login, a login through Dex is
# admitted or refused exactly as the service's gate says, Argo's SSO is on,
# the NetworkPolicy fence keeps proxied services reachable only through their
# proxy, and a preview's CI identity cannot touch this environment's Dex
# clients. Exit non-zero on the first failure.
#
#   NAME_PREFIX          the workloads name_prefix (default empty)
#   WITH_JUPYTERHUB=1    also check the hub
#   WITH_OIDC=0          skip the auth checks (auth.mode != "oidc")
#   WITH_TENANTS=0|1     Keycloak + tenants (enable_keycloak): run
#                        verify-tenants.sh instead of the mock/password-DB
#                        logins; default: whether a keycloak namespace exists
#   DEX_EMAIL / DEX_PASSWORD   the password-DB user (admin@example.com / password)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
example="$here/.."

P="${NAME_PREFIX:-}"
TIMEOUT="${TIMEOUT:-10m}"
WITH_OIDC="${WITH_OIDC:-1}"
DEX_EMAIL="${DEX_EMAIL:-admin@example.com}"
DEX_PASSWORD="${DEX_PASSWORD:-password}"
DEX_ISSUER="${DEX_ISSUER:-http://dex.dex.svc.cluster.local:5556/dex}"
CURL_IMAGE="curlimages/curl:8.16.0"
if [ -z "${WITH_TENANTS:-}" ]; then
  WITH_TENANTS=0
  kubectl get namespace keycloak >/dev/null 2>&1 && WITH_TENANTS=1
fi

rollout() {
  echo "-- $1: deployments"
  local d
  for d in $(kubectl -n "$1" get deployments -o name); do
    kubectl -n "$1" rollout status "$d" --timeout="$TIMEOUT"
  done
}

if [ "$WITH_OIDC" = "1" ]; then
  rollout dex
fi
if [ "$WITH_TENANTS" = "1" ]; then
  echo "-- keycloak: statefulset"
  kubectl -n keycloak rollout status statefulset/keycloak --timeout="$TIMEOUT"
  for ns in t-lab-ray t-acme-ray t-acme-argo t-acme-dagster; do rollout "$ns"; done
  for c in t-lab-ray t-acme-ray; do
    echo "-- $c: RayCluster ready"
    kubectl -n "$c" wait "raycluster/$c-cluster" --for=jsonpath='{.status.state}'=ready --timeout="$TIMEOUT"
  done
fi
rollout "${P}webapp"
rollout "${P}mlflow"
rollout "${P}dagster"
rollout "${P}argo"

echo "-- ${P}ray: RayCluster ready"
kubectl -n "${P}ray" wait "raycluster/${P}ray-cluster" --for=jsonpath='{.status.state}'=ready --timeout="$TIMEOUT"

if [ "${WITH_JUPYTERHUB:-0}" = "1" ]; then
  rollout "${P}jupyterhub"
fi

# In-cluster HTTP checks from long-lived curl pods (kubectl exec is
# deterministic where `kubectl run --rm -i` can lose a short pod's output), so
# no port-forwards are needed and it works identically on CI runners.
#
# The main probe runs in namespace "verify", which main.tf names as the
# ingress namespace (network_policies.ingress_namespaces): it sees what an
# ingress controller sees -- the login proxies and the unproxied UIs, never a
# proxied service's own pods. A second probe in the webapp's namespace plays
# a legitimate in-cluster client.
kubectl create namespace verify --dry-run=client -o yaml | kubectl apply -f - >/dev/null
pod="verify-probe-$RANDOM"
client_pod="verify-client-$RANDOM"
kubectl -n verify run "$pod" --restart=Never --quiet --image="$CURL_IMAGE" --command -- sleep 900 >/dev/null
kubectl -n "${P}webapp" run "$client_pod" --restart=Never --quiet --image="$CURL_IMAGE" --command -- sleep 900 >/dev/null
trap 'kubectl -n verify delete pod "$pod" --wait=false >/dev/null 2>&1 || true; kubectl -n "${P}webapp" delete pod "$client_pod" --wait=false >/dev/null 2>&1 || true' EXIT
kubectl -n verify wait --for=condition=Ready "pod/$pod" --timeout=2m >/dev/null
kubectl -n "${P}webapp" wait --for=condition=Ready "pod/$client_pod" --timeout=2m >/dev/null

probe() {
  echo "-- GET $1"
  kubectl -n verify exec "$pod" -- curl -sSf -o /dev/null --max-time 20 "$1"
}

# Assert a status code (no -f, redirects not followed); 000 = no connection.
status_from() {
  local ns="$1" p="$2" url="$3"
  kubectl -n "$ns" exec "$p" -- curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || true
}
expect_status() {
  local url="$1" want="$2" got
  got=$(status_from verify "$pod" "$url")
  echo "-- GET $url -> $got (want $want)"
  [ "$got" = "$want" ]
}

# Service names: the webapp Service carries webapp_app_name (unprefixed; its
# namespace is prefixed), Helm-derived services carry the prefixed release.
# Argo's UI index is served without a token in every auth mode; its API is not.
probe "http://webapp.${P}webapp.svc.cluster.local/"
probe "http://${P}argo-server.${P}argo.svc.cluster.local:2746/"

# The services' own health, from a client the fence admits (the webapp calls
# Dagster to trigger runs and logs to MLflow).
for url in "http://${P}mlflow.${P}mlflow.svc.cluster.local/health" \
  "http://${P}dagster-dagster-webserver.${P}dagster.svc.cluster.local/server_info"; do
  got=$(status_from "${P}webapp" "$client_pod" "$url")
  echo "-- GET $url from ${P}webapp -> $got (want 200)"
  [ "$got" = "200" ]
done

if [ "$WITH_OIDC" != "1" ]; then
  expect_status "http://${P}argo-server.${P}argo.svc.cluster.local:2746/api/v1/version" 200
  echo "== all workloads healthy"
  exit 0
fi

# MLflow is proxied only without tenants; with them it runs its own OIDC and
# its front door is the ingress itself.
proxied_urls=("http://${P}dagster-dagster-webserver.${P}dagster.svc.cluster.local/server_info")
[ "$WITH_TENANTS" = "1" ] || proxied_urls+=("http://${P}mlflow.${P}mlflow.svc.cluster.local/health")

echo "-- the fence: from the ingress namespace, proxied services are reachable only through their proxy"
for url in "${proxied_urls[@]}"; do
  got=$(status_from verify "$pod" "$url")
  echo "-- GET $url from verify -> $got (want 000: refused)"
  [ "$got" = "000" ]
done

# ------------------------------------------------------------------------------
# Auth (main.tf: auth.mode = "oidc", Dagster gated on group "authors")
# ------------------------------------------------------------------------------

echo "-- Dex issues: discovery document"
probe "$DEX_ISSUER/.well-known/openid-configuration"

echo "-- every protected UI sends an anonymous request to the login"
expect_status "http://dagster-auth.${P}dagster.svc.cluster.local/" 302
expect_status "http://ray-auth.${P}ray.svc.cluster.local/"         302
if [ "$WITH_TENANTS" != "1" ]; then
  expect_status "http://mlflow-auth.${P}mlflow.svc.cluster.local/" 302
fi

echo "-- Argo: native SSO (API refuses anonymous callers, login goes to Dex)"
expect_status "http://${P}argo-server.${P}argo.svc.cluster.local:2746/api/v1/info" 401
expect_status "http://${P}argo-server.${P}argo.svc.cluster.local:2746/oauth2/redirect?redirect=/workflows" 302

# The login dance (scripts/oidc-login.sh) runs inside the same pod so the
# cookie jar and the redirect chain stay in one place.
login() {
  # login <service> <connector> [email] [password] -> prints "<status> <userinfo>"
  local svc="$1"; shift
  local base="http://${svc}-auth.${P}${svc}.svc.cluster.local"
  kubectl -n verify exec -i "$pod" -- env USERINFO_URL="$base/oauth2/userinfo" sh -s -- "$base/oauth2/start?rd=%2F" "$DEX_ISSUER" "$@" <"$here/oidc-login.sh" | tr '\n' ' '
}

if [ "$WITH_TENANTS" = "1" ]; then
  # shellcheck source=verify-tenants.sh
  source "$here/verify-tenants.sh"
else

echo "-- password-DB user (no groups): admitted to MLflow"
out=$(login mlflow local "$DEX_EMAIL" "$DEX_PASSWORD"); echo "   $out"
[[ "$out" == 200* ]] && [[ "$out" == *"$DEX_EMAIL"* ]]

echo "-- password-DB user (no groups): refused by Dagster's group gate"
out=$(login dagster local "$DEX_EMAIL" "$DEX_PASSWORD"); echo "   $out"
[[ "$out" == 403* ]]

echo "-- mock user (group authors): admitted to Dagster"
out=$(login dagster mock); echo "   $out"
[[ "$out" == 200* ]] && [[ "$out" == *authors* ]]

fi

# ------------------------------------------------------------------------------
# Client ownership (modules/dex client_admission): a preview's CI identity may
# manage pr<N>- clients only. "preview-ci" is impersonated, with just enough
# RBAC on OAuth2Clients to show that the policy, not RBAC, is what refuses.
# ------------------------------------------------------------------------------

echo "-- admission: preview-ci may manage pr<N>- clients, not this environment's"
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: preview-ci-clients, namespace: dex }
rules:
  - apiGroups: ["dex.coreos.com"]
    resources: ["oauth2clients"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: preview-ci-clients, namespace: dex }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: preview-ci-clients }
subjects:
  - { apiGroup: rbac.authorization.k8s.io, kind: User, name: preview-ci }
YAML
kubectl --as=preview-ci -n dex apply -f - >/dev/null <<'YAML'
apiVersion: dex.coreos.com/v1
kind: OAuth2Client
metadata: { name: verify-preview-client, namespace: dex }
id: pr9-verify
secret: not-a-real-secret
name: pr9 verify probe
redirectURIs: ["http://pr9.invalid/callback"]
YAML
kubectl --as=preview-ci -n dex delete oauth2client verify-preview-client >/dev/null
echo "   preview-ci created and deleted its pr9- client"
prod_client=$(kubectl -n dex get oauth2clients -o jsonpath='{range .items[?(@.id=="oauth2-proxy")]}{.metadata.name}{end}')
if out=$(kubectl --as=preview-ci -n dex patch oauth2client "$prod_client" --type=merge -p '{"redirectURIs":["https://evil.invalid/callback"]}' 2>&1); then
  echo "   preview-ci was allowed to rewrite the environment's client: $out" >&2
  exit 1
fi
[[ "$out" == *"may only manage OAuth2Clients"* ]]
echo "   preview-ci refused on the environment's own client: ${out##*: }"
kubectl -n dex delete rolebinding,role preview-ci-clients >/dev/null

echo "== all workloads healthy, auth gates hold"
