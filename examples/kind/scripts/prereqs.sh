#!/usr/bin/env bash
# Install what modules/workloads expects a cluster to provide (README "Cluster
# prerequisites") plus a local data backend, on the CURRENT kubectl context:
#   - KubeRay operator          (enable_ray / enable_dagster)
#   - Argo Workflows CRDs       (enable_argo_workflows; the controller is per env)
#   - metrics-server            (HPA; kind needs --kubelet-insecure-tls)
#   - MinIO + buckets           (S3-compatible object store; local data axis)
#   - Postgres + databases      (stands in for Neon)
# Idempotent. Used by examples/kind, examples/kind-aws-data (which skips MinIO)
# and .github/workflows/kind-smoke.yml.
#
#   MINIO_ROOT_USER / MINIO_ROOT_PASSWORD   default minio / minio12345
#   POSTGRES_USER / POSTGRES_PASSWORD       default postgres / postgres
#   WITH_MINIO=0                            skip MinIO (data lives in AWS)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prereqs="$here/../prereqs"

KUBERAY_VERSION="${KUBERAY_VERSION:-1.6.0}"
# Must match the appVersion of modules/workloads' argo_workflows_chart_version.
ARGO_WORKFLOWS_VERSION="${ARGO_WORKFLOWS_VERSION:-v4.1.3}"
WITH_MINIO="${WITH_MINIO:-1}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minio}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minio12345}"
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

if [ "$WITH_MINIO" = "1" ]; then
  echo "== MinIO"
  kubectl apply -f "$prereqs/minio.yaml"
  kubectl -n minio create secret generic minio-root \
    --from-literal=MINIO_ROOT_USER="$MINIO_ROOT_USER" \
    --from-literal=MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n minio rollout status deployment/minio --timeout=5m
  kubectl -n minio wait --for=condition=complete job/minio-buckets --timeout=5m
fi

echo "== prerequisites ready"
