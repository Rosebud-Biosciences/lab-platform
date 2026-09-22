# Local compute + local data: the whole workloads layer on a kind cluster with
# SeaweedFS and Postgres standing in for S3 and Neon. No AWS provider anywhere.
terraform {
  required_version = ">= 1.12"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.12.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    # The realm (enable_keycloak) and the notebook group roles, configured
    # from the host through kind's NodePorts.
    keycloak = {
      source  = "keycloak/keycloak"
      version = ">= 5.9"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.25"
    }
  }
}
