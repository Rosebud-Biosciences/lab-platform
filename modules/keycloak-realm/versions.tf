# The platform realm inside modules/keycloak: tenants as group subtrees,
# superadmins, delegated tenant and group admins (fine-grained admin
# permissions v2), the Dex client and the upstream identity providers.
# The keycloak provider is the caller's (initial_login = false lets a plan run
# before Keycloak exists).
terraform {
  required_version = ">= 1.12"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = ">= 5.9"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}
