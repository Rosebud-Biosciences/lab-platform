# What a preview's deploy identity may do outside its own namespaces, and the
# admission policy that holds it to preview-prefixed names. Cloud-agnostic:
# kubernetes + kubectl providers only, inherited from the caller.
terraform {
  required_version = ">= 1.12"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.12.1"
    }
    # The ValidatingAdmissionPolicy, applied without a plan-time API call
    # (as modules/dex's client_admission is).
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
  }
}
