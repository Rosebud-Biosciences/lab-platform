# ------------------------------------------------------------------------------
# WORKLOADS MODULE - DAGSTER CODE LOCATIONS (var.dagster_code_locations)
#
# More code locations in the one Dagster: a tenant's (modules/tenancy) or a
# team's. Each is a user-code deployment with its own ServiceAccount (e.g. an
# IRSA role scoped to the tenant's data) and its own Secret, and through
# includeConfigInLaunchedRuns its runs launch with the same identity, so what
# a location's assets can read and write is that identity's business. The
# platform's own identity (the dagster identity contract) is NOT given to
# them. What is shared is the Dagster UI, run history, logs and asset catalog:
# everyone who can open Dagster sees every location (docs/tenancy.md).
# ------------------------------------------------------------------------------

locals {
  # "repo[:tag]" -> chart image block; a registry port (host:5000/repo) is not a tag.
  dagster_default_image = var.dagster_user_code_image == "" ? null : {
    repository = regex("^(.+?)(?::([^:/]+))?$", var.dagster_user_code_image)[0]
    tag        = coalesce(regex("^(.+?)(?::([^:/]+))?$", var.dagster_user_code_image)[1], "latest")
    pullPolicy = "IfNotPresent"
  }

  dagster_locations = local.enable_dagster ? var.dagster_code_locations : {}

  dagster_extra_locations = [
    for name, loc in local.dagster_locations : {
      name = name
      image = {
        repository = regex("^(.+?)(?::([^:/]+))?$", loc.image)[0]
        tag        = coalesce(regex("^(.+?)(?::([^:/]+))?$", loc.image)[1], "latest")
        pullPolicy = "IfNotPresent"
      }
      dagsterApiGrpcArgs = loc.grpc_args
      port               = 3030
      serviceAccountName = kubernetes_service_account_v1.dagster_location[name].metadata[0].name
      env                = merge(local.service_urls_env, loc.env)
      envSecrets = concat(
        [{ name = kubernetes_secret_v1.dagster_location[name].metadata[0].name }],
        loc.mlflow_account != "" ? [{ name = "mlflow-credentials-${name}" }] : [],
      )
      includeConfigInLaunchedRuns = { enabled = true }
      nodeSelector                = local.scheduling.dagster.node_selector
      tolerations                 = local.scheduling.dagster.tolerations
    }
  ]
}

resource "kubernetes_service_account_v1" "dagster_location" {
  for_each = local.dagster_locations

  metadata {
    name        = "${local.prefix}dagster-${each.key}"
    namespace   = local.dagster_namespace
    annotations = each.value.service_account_annotations
    labels      = { "lab-platform.io/code-location" = each.key }
  }
}

resource "kubernetes_secret_v1" "dagster_location" {
  for_each = local.dagster_locations

  metadata {
    name      = "dagster-location-${each.key}-env"
    namespace = local.dagster_namespace
  }

  data = each.value.secret_env
}
