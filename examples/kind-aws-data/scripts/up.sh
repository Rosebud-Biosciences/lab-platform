#!/usr/bin/env bash
# Laptop flow for examples/kind-aws-data: kind cluster with a hosted issuer ->
# prerequisites (no MinIO: the data is in AWS) -> tofu apply -> verify.
#
#   OIDC_BUCKET   (required) globally unique, DNS-safe, no dots
#   AWS_REGION    (default us-west-2)
#   CLUSTER       (default lab-platform-aws)
# AWS credentials must be in the environment (a profile or SSO session).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
example="$here/.."
: "${OIDC_BUCKET:?set OIDC_BUCKET}"
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER="${CLUSTER:-lab-platform-aws}"

"$here/kind-up.sh"
WITH_MINIO=0 "$here/../../kind/scripts/prereqs.sh"

tofu -chdir="$example" init -input=false
tofu -chdir="$example" apply -input=false -auto-approve \
  -var "oidc_bucket_name=$OIDC_BUCKET" -var "cluster_name=$CLUSTER" -var "region=$AWS_REGION" \
  -var "jwks_json=$(cat "$example/jwks.json")" "$@"

"$here/verify.sh"
