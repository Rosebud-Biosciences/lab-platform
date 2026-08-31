# Copy-on-write Neon Postgres branches for a single preview environment. One
# branch + endpoint per source project; connection strings are exported for the
# workloads module to consume. Branches/endpoints are deleted on `tofu destroy`.
# The neon provider is inherited from the caller.
terraform {
  required_version = ">= 1.12"

  required_providers {
    neon = {
      source  = "kislerdm/neon"
      version = ">= 0.6.3"
    }
  }
}
