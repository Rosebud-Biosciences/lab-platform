# Reusable "workloads" module: webapp + JupyterHub + Dagster + MLflow + Ray,
# plus their Karpenter NodePools. Designed to be instantiated MULTIPLE TIMES
# against an EXISTING EKS cluster with a distinct `name_prefix`, so prod and any
# number of preview environments coexist on one cluster without namespace /
# release-name / hostname collisions.
#
# Providers (kubernetes / helm / kubectl / aws) are inherited from the caller,
# which points them at the target cluster.
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }
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
