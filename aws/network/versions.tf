terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
    # Only exercised when enable_tailscale_subnet_router = true. Callers that
    # leave the router off never need to configure this provider (the resources
    # that use it have count = 0), but it must be declared so the module can
    # reference it.
    tailscale = {
      source  = "tailscale/tailscale"
      version = ">= 0.18"
    }
  }
}
