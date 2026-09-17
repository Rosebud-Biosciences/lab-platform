# Reusable "workloads" module: webapp + JupyterHub + Dagster + MLflow + Ray on
# ANY Kubernetes cluster. Designed to be instantiated MULTIPLE TIMES against an
# existing cluster with a distinct `name_prefix`, so prod and any number of
# preview environments coexist on one cluster without namespace / release-name /
# hostname collisions.
#
# Nothing here knows which cloud the cluster runs on or where the data lives.
# Cloud specifics arrive through four contract inputs -- workload_identity,
# scheduling, jupyterhub_shared_storage, and the public-ingress class /
# annotations -- produced by a backend adapter (aws/data-adapter and
# aws/compute-adapter for AWS) or written by hand (examples/kind).
#
# Providers (kubernetes / helm / kubectl) are inherited from the caller, which
# points them at the target cluster.
terraform {
  required_version = ">= 1.12"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.12.1"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}
