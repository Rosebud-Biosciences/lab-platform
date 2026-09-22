#!/usr/bin/env bash
# Laptop flow for examples/kind: create the cluster, install prerequisites,
# apply the workloads, verify. Re-runnable; `scripts/down.sh` removes it all.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
example="$here/.."
CLUSTER="${CLUSTER:-lab-platform}"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --config "$example/kind-config.yaml" --name "$CLUSTER" --wait 2m
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

"$here/prereqs.sh"

tofu -chdir="$example" init -input=false
# Keycloak first: the realm's provider logs in to it (through the NodePort)
# during the full apply. A no-op when enable_keycloak = false.
tofu -chdir="$example" apply -input=false -auto-approve -target=module.keycloak "$@"
tofu -chdir="$example" apply -input=false -auto-approve "$@"

"$here/verify.sh"
tofu -chdir="$example" output port_forwards
