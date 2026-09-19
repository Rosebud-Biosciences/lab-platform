# Dex: the platform's OpenID Connect issuer. One per cluster; every
# environment's services (modules/workloads `auth`) trust its issuer URL and
# register their own OAuth2 clients as CRs in its namespace. Cloud-agnostic:
# kubernetes + helm providers only, inherited from the caller.
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
    # client_admission's ValidatingAdmissionPolicy (applied without a
    # plan-time API call, like the workloads module's CRs).
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
  }
}
