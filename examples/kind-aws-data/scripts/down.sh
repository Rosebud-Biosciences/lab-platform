#!/usr/bin/env bash
# Tear down examples/kind-aws-data: destroy the AWS side and the workloads,
# then delete the cluster. Needs the same -var values as the apply (pass them
# as arguments, or re-export OIDC_BUCKET / CLUSTER / AWS_REGION).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
example="$here/.."
CLUSTER="${CLUSTER:-lab-platform-aws}"
AWS_REGION="${AWS_REGION:-us-west-2}"

if [ -f "$example/terraform.tfstate" ] || [ -d "$example/.terraform" ]; then
  tofu -chdir="$example" destroy -input=false -auto-approve \
    -var "oidc_bucket_name=${OIDC_BUCKET:-}" -var "cluster_name=$CLUSTER" -var "region=$AWS_REGION" \
    -var "jwks_json=$(cat "$example/jwks.json" 2>/dev/null || echo '{"keys":[]}')" "$@" || true
fi
kind delete cluster --name "$CLUSTER"
rm -f "$example/jwks.json"
