# ------------------------------------------------------------------------------
# TENANCY - the matrix, validated, turned into inputs
#
# What a shared instance can isolate decides who may share it:
#
#   webapp       yes   row-level security + app groups
#   jupyterhub   yes   a profile per group: ServiceAccount, cloud role, DB
#                      role, directory, labels the tenant's stamps admit
#   mlflow       yes   per-experiment permissions (OIDC plugin): each tenant's
#                      groups on experiments named <tenant>/...
#   dagster      compute only   a code location per tenant running as the
#                      tenant's identity; UI, logs and catalog visible to all
#   ray, argo    no    one identity per instance
#
# External tenants may share only "yes" rows. Internal tenants may share
# everything; sharing Ray or Argo means their admins join the platform
# instance's gate, accepting the platform's identity.
# ------------------------------------------------------------------------------

locals {
  isolates_tenants = { webapp = true, jupyterhub = true, mlflow = true, dagster = false, ray = false, argo = false }

  member_groups = { for t, v in var.tenants : t => [for g in keys(v.groups) : "/${t}/${g}"] }
  admin_groups  = { for t, v in var.tenants : t => concat(["/${t}/admins"], [for g in keys(v.groups) : "/${t}/${g}/admins"]) }
  all_groups    = { for t in keys(var.tenants) : t => concat(local.member_groups[t], local.admin_groups[t]) }

  shared   = { for svc in keys(local.isolates_tenants) : svc => [for t, v in var.tenants : t if v.services[svc] == "shared"] }
  isolated = { for t, v in var.tenants : t => [for svc, mode in v.services : svc if mode == "isolated"] }

  identity = {
    for t in keys(var.tenants) : t => lookup(var.tenant_identity, t, { service_account_annotations = {}, env = {}, secret_env = {} })
  }

  platform_ns  = { for svc in ["dagster", "ray", "mlflow", "argo", "jupyterhub", "webapp"] : svc => "${var.platform_prefix}${svc}" }
  stamp_prefix = { for t in keys(var.tenants) : t => format(var.stamp_prefix, t) }

  # Argo rbac-rule: any of these groups.
  any_of = { for t in keys(var.tenants) : t => {
    members = join(" || ", [for g in local.member_groups[t] : "'${g}' in groups"])
    admins  = join(" || ", [for g in local.admin_groups[t] : "'${g}' in groups"])
  } }

  # --- Validation (surfaced as output preconditions) ---------------------------
  sharing_violations = flatten([
    for t, v in var.tenants : [
      for svc, mode in v.services : "${t}: ${svc} = \"shared\" (it cannot isolate tenants; use \"isolated\" or \"off\")"
      if v.trust == "external" && mode == "shared" && !local.isolates_tenants[svc]
    ]
  ])
  mlflow_violations = [
    for t, v in var.tenants : "${t}: mlflow = \"shared\" needs the platform MLflow on OIDC (platform_mlflow_oidc) to keep its experiments to itself"
    if v.trust == "external" && v.services.mlflow == "shared" && !var.platform_mlflow_oidc
  ]
  violations = concat(local.sharing_violations, local.mlflow_violations)

  mlflow_accounts = var.platform_mlflow_oidc ? { for t in local.shared.mlflow : t => "svc-${t}" } : {}

  # --- The shared instance's hooks ---------------------------------------------
  shared_hooks = {
    dagster_allowed_groups = distinct(concat([var.superadmin_group], flatten([for t in local.shared.dagster : local.all_groups[t]])))
    dagster_code_locations = {
      for t in local.shared.dagster : t => {
        image                       = var.tenants[t].dagster_image
        service_account_annotations = local.identity[t].service_account_annotations
        env                         = local.identity[t].env
        secret_env                  = local.identity[t].secret_env
        mlflow_account              = lookup(local.mlflow_accounts, t, "")
      } if var.tenants[t].dagster_image != ""
    }
    ray_allowed_groups = distinct(concat([var.superadmin_group], flatten([for t in local.shared.ray : local.admin_groups[t]])))
    argo_rbac_rules = {
      for t in local.shared.argo : "tenant-${t}" => { rule = local.any_of[t].admins, access = "write", precedence = 50 }
    }
    jupyterhub_allowed_groups = flatten([for t in local.shared.jupyterhub : local.all_groups[t]])
    jupyterhub_group_profiles = merge([
      for t in local.shared.jupyterhub : {
        for g in concat(local.member_groups[t], ["/${t}/admins"]) : g => {
          display_name                = g
          service_account_annotations = local.identity[t].service_account_annotations
          env                         = local.identity[t].env
          secret_env                  = merge(local.identity[t].secret_env, lookup(var.group_secret_env, g, {}))
          group_directory             = true
          replace_identity            = true
          # External tenants do not see the hub-wide shared directory.
          mount_shared = var.tenants[t].trust == "internal"
        }
      }
    ]...)
    mlflow_groups = flatten([for t in local.shared.mlflow : local.all_groups[t]])
    mlflow_group_rules = flatten([
      for t in local.shared.mlflow : concat(
        [for g in local.member_groups[t] : { group = g, regex = "^${t}/", permission = "EDIT", priority = 10 }],
        [for g in local.admin_groups[t] : { group = g, regex = "^${t}/", permission = "MANAGE", priority = 5 }],
      )
    ])
    # One MLflow account per tenant: its token in the tenant's stamps and in
    # its shared code location's Secret.
    mlflow_service_accounts = {
      for t, account in local.mlflow_accounts : account => {
        secrets = concat(
          [for svc in ["dagster", "ray", "webapp"] : { namespace = "${local.stamp_prefix[t]}${svc}", name = "mlflow-credentials" } if contains(local.isolated[t], svc)],
          var.tenants[t].services.dagster == "shared" && var.tenants[t].dagster_image != "" ? [{ namespace = local.platform_ns.dagster, name = "mlflow-credentials-${t}" }] : [],
        )
        experiment_patterns = [{ regex = "^${t}/", permission = "EDIT", priority = 50 }]
      }
    }
    postgres_data_groups = flatten([for t, v in var.tenants : [for g, gv in v.groups : "/${t}/${g}" if gv.data]])
  }

  # --- Per-tenant stamps ---------------------------------------------------------
  stamps = {
    for t, v in var.tenants : t => {
      name_prefix = local.stamp_prefix[t]
      trust       = v.trust
      enable = {
        ray     = contains(local.isolated[t], "ray")
        argo    = contains(local.isolated[t], "argo")
        dagster = contains(local.isolated[t], "dagster")
      }
      dagster_image = v.dagster_image
      identity      = local.identity[t]
      # Every group of the tenant opens its Ray dashboard and Dagster (no
      # read-only mode; they reach no data their notebooks cannot).
      protect = {
        ray     = { allowed_groups = local.all_groups[t] }
        dagster = { allowed_groups = local.all_groups[t] }
      }
      argo_rbac_rules = {
        admins  = { rule = local.any_of[t].admins, access = "write", precedence = 20 }
        members = { rule = local.any_of[t].members, access = "read", precedence = 10 }
      }
      network_policies = {
        tenant = t
        # The tenant's notebooks (platform JupyterHub pods labelled with it)
        # reach its stamps' Ray and MLflow clients; an internal tenant's
        # shared Dagster code location reaches its Ray.
        extra_peers = {
          ray = concat(
            [{ namespace_labels = { "lab-platform.io/service" = "jupyterhub" }, pod_labels = { "lab-platform.io/tenant" = t } }],
            v.trust == "internal" && v.services.dagster == "shared" ? [{ namespace_labels = { "kubernetes.io/metadata.name" = local.platform_ns.dagster }, pod_labels = {} }] : [],
          )
          dagster = [{ namespace_labels = { "lab-platform.io/service" = "jupyterhub" }, pod_labels = { "lab-platform.io/tenant" = t } }]
        }
      }
      mlflow = {
        account            = lookup(local.mlflow_accounts, t, "")
        client_credentials = contains(keys(local.mlflow_accounts), t) && length(setintersection(toset(local.isolated[t]), toset(["dagster", "ray", "webapp"]))) > 0
        sync_namespace     = local.platform_ns.mlflow
      }
    } if length(local.isolated[t]) > 0
  }
}
