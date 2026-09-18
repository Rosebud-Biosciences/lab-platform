#!/usr/bin/env bash
# Install what modules/workloads expects a cluster to provide (README "Cluster
# prerequisites") plus a local data backend, on the CURRENT kubectl context:
#   - KubeRay operator          (enable_ray / enable_dagster)
#   - Argo Workflows CRDs       (enable_argo_workflows; the controller is per env)
#   - metrics-server            (HPA; kind needs --kubelet-insecure-tls)
#   - SeaweedFS + buckets       (S3-compatible object store; local data axis)
#   - Postgres + databases      (stands in for Neon)
# Idempotent. Used by examples/kind, examples/kind-aws-data (which skips the
# object store) and .github/workflows/kind-smoke.yml.
#
#   S3_ACCESS_KEY / S3_SECRET_KEY           default seaweedfs / seaweedfs12345
#   POSTGRES_USER / POSTGRES_PASSWORD       default postgres / postgres
#   WITH_S3=0                               skip SeaweedFS (data lives in AWS)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prereqs="$here/../prereqs"

KUBERAY_VERSION="${KUBERAY_VERSION:-1.6.0}"
# Must match the appVersion of modules/workloads' argo_workflows_chart_version.
ARGO_WORKFLOWS_VERSION="${ARGO_WORKFLOWS_VERSION:-v4.1.3}"
WITH_S3="${WITH_S3:-1}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-seaweedfs}"
S3_SECRET_KEY="${S3_SECRET_KEY:-seaweedfs12345}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"

echo "== KubeRay operator ${KUBERAY_VERSION}"
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ >/dev/null
helm repo update kuberay >/dev/null
helm upgrade --install kuberay-operator kuberay/kuberay-operator \
  --version "$KUBERAY_VERSION" --namespace kuberay-system --create-namespace --wait --timeout 5m

echo "== Argo Workflows CRDs ${ARGO_WORKFLOWS_VERSION} (what aws/eks-platform enable_argo_workflows installs)"
for crd in clusterworkflowtemplates cronworkflows workflowartifactgctasks workfloweventbindings workflows workflowtaskresults workflowtasksets workflowtemplates; do
  kubectl apply --server-side -f "https://raw.githubusercontent.com/argoproj/argo-workflows/${ARGO_WORKFLOWS_VERSION}/manifests/base/crds/minimal/argoproj.io_${crd}.yaml" >/dev/null
done
kubectl wait --for=condition=Established crd/workflows.argoproj.io --timeout=60s >/dev/null

echo "== metrics-server"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update metrics-server >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system --set 'args={--kubelet-insecure-tls}' --wait --timeout 5m

echo "== Postgres"
kubectl apply -f "$prereqs/postgres.yaml"
kubectl -n postgres create secret generic postgres-root \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n postgres rollout status deployment/postgres --timeout=5m

if [ "$WITH_S3" = "1" ]; then
  echo "== SeaweedFS"
  kubectl apply -f "$prereqs/seaweedfs.yaml"
  # One Secret serves both: s3.json is SeaweedFS's identity file (mounted into
  # the server), the AWS_* keys feed the bucket Job's aws-cli via envFrom.
  s3_json=$(printf '{"identities":[{"name":"admin","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}' \
    "$S3_ACCESS_KEY" "$S3_SECRET_KEY")
  kubectl -n seaweedfs create secret generic seaweedfs-s3 \
    --from-literal=s3.json="$s3_json" \
    --from-literal=AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n seaweedfs rollout status deployment/seaweedfs --timeout=5m
  kubectl -n seaweedfs wait --for=condition=complete job/seaweedfs-buckets --timeout=5m
fi

echo "== prerequisites ready"
