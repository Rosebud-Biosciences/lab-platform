# Keycloak: the platform's user store, one per cluster, behind Dex. Holds the
# tenants' users and groups and lets delegated admins manage their own part of
# the tree (modules/keycloak-realm). Cloud-agnostic: kubernetes + helm +
# random only, the first two inherited from the caller.
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
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}
