output "realm_tenants" {
  description = "The tenants map as modules/keycloak-realm takes it"
  value       = { for t, v in var.tenants : t => { groups = { for g in keys(v.groups) : g => {} } } }

  precondition {
    condition     = length(local.violations) == 0
    error_message = "The tenancy matrix puts tenants where they cannot be isolated:\n  ${join("\n  ", local.violations)}"
  }
}

output "shared" {
  description = <<-EOT
    Inputs for the platform's shared workloads instance (merge with its own):
    dagster_allowed_groups / ray_allowed_groups (protect gates),
    dagster_code_locations, argo_rbac_rules, jupyterhub_allowed_groups,
    jupyterhub_group_profiles, mlflow_groups, mlflow_group_rules,
    mlflow_service_accounts, and postgres_data_groups
    (modules/postgres-group-roles).
  EOT
  value       = local.shared_hooks

  precondition {
    condition     = length(local.violations) == 0
    error_message = "The tenancy matrix puts tenants where they cannot be isolated:\n  ${join("\n  ", local.violations)}"
  }
}

output "stamps" {
  description = "Per tenant with an isolated service: the spec of its modules/workloads stamp (name_prefix, which services, gates, Argo rules, network_policies, identity, MLflow account)"
  value       = local.stamps

  precondition {
    condition     = length(local.violations) == 0
    error_message = "The tenancy matrix puts tenants where they cannot be isolated:\n  ${join("\n  ", local.violations)}"
  }
}

output "groups" {
  description = "Per tenant: member and admin group paths"
  value       = { for t in keys(var.tenants) : t => { members = local.member_groups[t], admins = local.admin_groups[t] } }
}
