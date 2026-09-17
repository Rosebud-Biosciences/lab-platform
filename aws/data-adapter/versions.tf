# AWS data-axis adapter for modules/workloads: per-service IAM roles that
# reach AWS data stores (S3, S3 Tables, ECR) from pods running on ANY cluster
# whose OIDC issuer AWS trusts -- the EKS cluster's own issuer, or a foreign
# one registered with aws/oidc-provider. Emits the workload_identity contract.
# The AWS provider is inherited from the caller.
terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }
  }
}
