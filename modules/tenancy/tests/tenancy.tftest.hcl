variables {
  tenants = {
    lab = {
      trust         = "internal"
      groups        = { authors = {}, pipelines = { data = false } }
      services      = { ray = "isolated", argo = "shared", dagster = "shared" }
      dagster_image = "ghcr.io/lab/code:1"
    }
    acme = {
      trust    = "external"
      groups   = { research = {} }
      services = { ray = "isolated", argo = "isolated", dagster = "isolated" }
      data     = { database = "own_database", bucket = "own" }
    }
  }
  tenant_identity  = { acme = { service_account_annotations = { "eks.amazonaws.com/role-arn" = "arn:acme" } } }
  group_secret_env = { "/acme/research" = { DATABASE_URL = "postgresql://nb_acme__research@db/app" } }
}

run "shared_hooks" {
  command = plan

  assert {
    condition     = output.shared.dagster_allowed_groups == tolist(["/platform-admins", "/lab/authors", "/lab/pipelines", "/lab/admins", "/lab/authors/admins", "/lab/pipelines/admins"])
    error_message = "the shared Dagster admits superadmins and the groups of tenants on it"
  }
  assert {
    condition     = keys(output.shared.dagster_code_locations) == ["lab"] && output.shared.dagster_code_locations["lab"].mlflow_account == "svc-lab"
    error_message = "a tenant with code on the shared Dagster gets a code location with its own MLflow account"
  }
  assert {
    condition     = output.shared.argo_rbac_rules["tenant-lab"].access == "write" && strcontains(output.shared.argo_rbac_rules["tenant-lab"].rule, "'/lab/admins' in groups")
    error_message = "an internal tenant sharing Argo: its admins join the platform instance's rules"
  }
  assert {
    condition     = output.shared.jupyterhub_group_profiles["/acme/research"].mount_shared == false && output.shared.jupyterhub_group_profiles["/lab/authors"].mount_shared && output.shared.jupyterhub_group_profiles["/acme/research"].secret_env["DATABASE_URL"] == "postgresql://nb_acme__research@db/app"
    error_message = "a profile per group, the tenant's identity plus the group's DB role; external tenants without the shared dir"
  }
  assert {
    condition     = contains(output.shared.mlflow_group_rules, { group = "/acme/research", regex = "^acme/", permission = "EDIT", priority = 10 }) && contains(output.shared.mlflow_group_rules, { group = "/acme/admins", regex = "^acme/", permission = "MANAGE", priority = 5 })
    error_message = "each tenant's groups edit (admins manage) experiments named <tenant>/..."
  }
  assert {
    condition     = [for s in output.shared.mlflow_service_accounts["svc-acme"].secrets : "${s.namespace}/${s.name}"] == ["t-acme-dagster/mlflow-credentials", "t-acme-ray/mlflow-credentials"] && [for s in output.shared.mlflow_service_accounts["svc-lab"].secrets : "${s.namespace}/${s.name}"] == ["t-lab-ray/mlflow-credentials", "dagster/mlflow-credentials-lab"]
    error_message = "a tenant's MLflow token reaches its stamps and its shared code location"
  }
  assert {
    condition     = tolist(output.shared.postgres_data_groups) == tolist(["/acme/research", "/lab/authors"])
    error_message = "data groups get Postgres roles; data = false opts out"
  }
}

run "stamps" {
  command = plan

  assert {
    condition     = output.stamps["acme"].enable == { ray = true, argo = true, dagster = true } && output.stamps["lab"].enable == { ray = true, argo = false, dagster = false }
    error_message = "a stamp holds exactly the tenant's isolated services"
  }
  assert {
    condition     = output.stamps["acme"].name_prefix == "t-acme-" && output.stamps["acme"].network_policies.tenant == "acme" && output.stamps["acme"].identity.service_account_annotations["eks.amazonaws.com/role-arn"] == "arn:acme"
    error_message = "stamps are prefixed, fenced to the tenant and run as its identity"
  }
  assert {
    condition     = output.stamps["acme"].argo_rbac_rules.admins.access == "write" && output.stamps["acme"].argo_rbac_rules.members.access == "read" && output.stamps["acme"].argo_rbac_rules.admins.precedence > output.stamps["acme"].argo_rbac_rules.members.precedence
    error_message = "in a tenant's Argo, admins edit and members view"
  }
  assert {
    condition     = length(output.stamps["lab"].network_policies.extra_peers.ray) == 2 && length(output.stamps["acme"].network_policies.extra_peers.ray) == 1
    error_message = "the tenant's notebooks reach its Ray; an internal tenant's shared code location does too"
  }
}

run "external_tenants_cannot_share_what_cannot_isolate" {
  command = plan

  variables {
    tenants = {
      acme = { trust = "external", groups = { research = {} }, services = { dagster = "shared" } }
    }
  }

  expect_failures = [output.shared, output.stamps, output.realm_tenants]
}

run "external_mlflow_needs_oidc" {
  command = plan

  variables {
    platform_mlflow_oidc = false
    tenants = {
      acme = { trust = "external", groups = { research = {} }, services = { dagster = "off" } }
    }
  }

  expect_failures = [output.shared, output.stamps, output.realm_tenants]
}

run "trailing_underscore_is_refused" {
  command = plan

  variables {
    tenants = { "lab_" = { groups = { authors = {} } } }
  }

  expect_failures = [var.tenants]
}
