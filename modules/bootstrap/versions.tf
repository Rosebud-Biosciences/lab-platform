# One-time account bootstrap: the Terraform state backend (S3 + DynamoDB lock
# table) and the GitHub Actions OIDC roles that CI and the preview workflows
# assume. Apply this with a local backend first, then migrate state into the
# bucket it creates. The AWS provider is configured by the caller.
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.40"
    }
  }
}
