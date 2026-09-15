# Least-privilege data-plane access to PRODUCTION data stores for pods that work
# on dataset branches inside them (tether mode; see docs/preview-environments.md).
# The AWS provider is inherited from the caller.
terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.40"
    }
  }
}
