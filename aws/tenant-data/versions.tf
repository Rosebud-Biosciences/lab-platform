# One tenant's data and identity on AWS: an IAM role its ServiceAccounts
# assume (stamps, JupyterHub group profiles, Dagster code locations), its
# slice of storage (a prefix of the shared bucket, or a bucket of its own),
# and optionally its own database. Instantiate once per tenant (for_each at
# the root, over modules/tenancy's inputs).
terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.40"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.25"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}
