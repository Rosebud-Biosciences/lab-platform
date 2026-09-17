#!/usr/bin/env bash
# Create the kind cluster with its ServiceAccount issuer pointed at the S3
# bucket aws/oidc-provider will populate, then export the cluster's JWKS for
# `tofu apply`. The issuer URL has to be baked in before the API server mints
# its first token, and the JWKS only exists once the cluster runs -- hence
# this ordering. Re-runnable.
#
#   OIDC_BUCKET   (required) the discovery bucket name, e.g. lab-kind-oidc-<account>
#   AWS_REGION    (default us-west-2) the bucket's region
#   CLUSTER       (default lab-platform-aws) kind cluster name; also the discovery prefix
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
example="$here/.."
: "${OIDC_BUCKET:?set OIDC_BUCKET to the discovery bucket name}"
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER="${CLUSTER:-lab-platform-aws}"

ISSUER="https://${OIDC_BUCKET}.s3.${AWS_REGION}.amazonaws.com/${CLUSTER}"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --wait 2m --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        service-account-issuer: ${ISSUER}
        service-account-jwks-uri: ${ISSUER}/keys.json
EOF
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# The public keys that sign this cluster's tokens; aws/oidc-provider publishes
# them at ${ISSUER}/keys.json so IAM can verify a projected token.
kubectl get --raw /openid/v1/jwks > "$example/jwks.json"
echo "issuer:  $ISSUER"
echo "jwks:    $example/jwks.json ($(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["keys"]))' "$example/jwks.json") key(s))"
echo
echo "next:    tofu -chdir=$example apply -var oidc_bucket_name=$OIDC_BUCKET -var cluster_name=$CLUSTER -var region=$AWS_REGION -var jwks_json=\"\$(cat $example/jwks.json)\""
