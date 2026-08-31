terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      # >= 6.40: blocked_encryption_types round-trips cleanly (Optional +
      # Computed, hashicorp/terraform-provider-aws#47320); older 6.x loops on
      # a perpetual SSE diff and < 6.22 rejects the argument entirely.
      source  = "hashicorp/aws"
      version = ">= 6.40"
    }
  }
}
