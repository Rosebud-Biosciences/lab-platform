# Tenancy: which tenant runs where. Pure computation -- no providers, no
# resources. It validates the tenants map against what each service can
# isolate and returns (a) the per-tenant hooks to feed the platform's shared
# workloads instance and (b) a spec per tenant for its isolated stamp, which
# the caller turns into `module "tenant_stamp" { for_each = ... }` of
# modules/workloads with its own images, databases and identities.
terraform {
  required_version = ">= 1.12"
}
