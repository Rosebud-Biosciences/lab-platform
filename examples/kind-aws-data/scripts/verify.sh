#!/usr/bin/env bash
# Prove the bridge: the workloads are healthy (examples/kind's checks), and a
# pod running as the Dagster ServiceAccount -- with nothing but the projected
# token modules/workloads mounts and the env aws/data-adapter emitted -- can
# assume its IAM role and list the data bucket. No keys anywhere.
#
# Run from anywhere after `tofu apply`; reads the example's outputs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
example="$here/.."

# Same health checks as the local example (NAME_PREFIX honoured). This example
# runs no Dex (auth stays in headers mode), so the OIDC checks are skipped.
WITH_OIDC=0 "$here/../../kind/scripts/verify.sh"

ns="$(tofu -chdir="$example" output -json namespaces | python3 -c 'import json,sys; print(json.load(sys.stdin)["dagster"])')"
bucket="$(tofu -chdir="$example" output -raw data_bucket)"
identity="$(tofu -chdir="$example" output -json workload_identity)"

# A pod spec built from the contract exactly as the module builds it: the
# Dagster SA, the adapter's env, the projected token. Then ask STS who we are
# and S3 what we may see.
overrides="$(python3 - "$identity" "$bucket" <<'EOF'
import json, sys
d = json.loads(sys.argv[1])["dagster"]
tok = d.get("projected_token")
env = [{"name": k, "value": v} for k, v in d["env"].items()] + [{"name": "BUCKET", "value": sys.argv[2]}]
spec = {"spec": {
    "serviceAccountName": "dagster",
    "restartPolicy": "Never",
    "containers": [{
        "name": "aws",
        "image": "public.ecr.aws/aws-cli/aws-cli:2.32.0",
        "command": ["sh", "-c", "aws sts get-caller-identity && aws s3 ls \"s3://$BUCKET/\" && echo web-identity-ok"],
        "env": env,
        "volumeMounts": [{"name": "workload-identity-token", "mountPath": tok["mount_path"], "readOnly": True}] if tok else [],
    }],
    "volumes": [{"name": "workload-identity-token", "projected": {"sources": [{"serviceAccountToken": {
        "audience": tok["audience"], "expirationSeconds": tok["expiration_seconds"], "path": tok["file_name"]}}]}}] if tok else [],
}}
print(json.dumps(spec))
EOF
)"

echo "-- assume the Dagster role from a kind pod via web identity"
kubectl -n "$ns" run "web-identity-probe-$RANDOM" --rm -i --restart=Never --quiet \
  --image=public.ecr.aws/aws-cli/aws-cli:2.32.0 --overrides="$overrides" | tee /dev/stderr | grep -q web-identity-ok

echo "== AWS data reachable from kind with a per-service role"
