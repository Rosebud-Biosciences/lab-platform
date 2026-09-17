# Ephemeral, disposable object storage for a single preview environment: a
# processed-data S3 bucket that is torn down with the preview (force_destroy, no
# versioning). The AWS provider is inherited from the caller.
terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.40"
    }
  }
}
