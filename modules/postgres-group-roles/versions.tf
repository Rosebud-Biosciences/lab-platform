# Per-group Postgres login roles for notebooks and tenant compute. The
# postgresql provider is the caller's, connected as a role that may CREATE
# ROLE on the target server (e.g. the database owner on Neon).
terraform {
  required_version = ">= 1.12"

  required_providers {
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
