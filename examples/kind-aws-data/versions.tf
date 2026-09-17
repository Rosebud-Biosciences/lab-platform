# Local compute + AWS data: the workloads on a kind cluster, the data in AWS
# (an S3 bucket, optionally an S3 Tables namespace), joined by web-identity
# federation -- per-service IAM roles, no static keys.
terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.40"
    }
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
  }
}
