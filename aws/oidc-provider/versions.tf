# Registers a NON-EKS cluster's ServiceAccount token issuer with AWS IAM so
# aws/data-adapter roles can trust its pods (web-identity federation), and
# optionally hosts the issuer's discovery document + JWKS on S3 for clusters
# whose API server is not on the public internet (kind, on-prem).
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
