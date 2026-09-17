#!/usr/bin/env bash
# Tear down examples/kind: destroy the workloads (proves the module cleans up
# after itself), then delete the cluster.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
example="$here/.."
CLUSTER="${CLUSTER:-lab-platform}"

if [ -f "$example/terraform.tfstate" ] || [ -d "$example/.terraform" ]; then
  tofu -chdir="$example" destroy -input=false -auto-approve "$@" || true
fi
kind delete cluster --name "$CLUSTER"
