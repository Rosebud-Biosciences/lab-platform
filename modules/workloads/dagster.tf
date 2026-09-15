# ------------------------------------------------------------------------------
# WORKLOADS MODULE - DAGSTER CONTROL PLANE (namespaced by name_prefix)
#
# Deploys the official dagster/dagster Helm chart against an external Postgres,
# with an IRSA-backed service account and RBAC to manage Ray clusters in the ray
# namespace. Requires enable_ray = true (enforced by the precondition below).
# ------------------------------------------------------------------------------

locals {
  dagster_db_password_secret = "dagster-postgresql-secret"
}

resource "kubernetes_namespace_v1" "dagster" {
  count = local.enable_dagster ? 1 : 0

  metadata {
    name = local.dagster_namespace
  }

  lifecycle {
    precondition {
      condition     = var.enable_ray
      error_message = "enable_dagster = true requires enable_ray = true (Dagster launches runs against the Ray namespace)."
    }
  }
}

module "dagster_irsa" {
  count   = local.enable_dagster ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name            = "${var.cluster_name}-${local.prefix}dagster-sa"
  use_name_prefix = false

  policies = merge(
    { ecr_read = aws_iam_policy.ecr_read[0].arn },
    var.dagster_bucket_policies
  )

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${local.dagster_namespace}:${local.dagster_service_account}"]
    }
  }
}

resource "kubernetes_service_account_v1" "dagster" {
  count = local.enable_dagster ? 1 : 0

  metadata {
    name        = local.dagster_service_account
    namespace   = kubernetes_namespace_v1.dagster[0].metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" : module.dagster_irsa[0].arn }
  }
}

# RBAC so Dagster runs can create/delete Ray clusters in the ray namespace.
resource "kubernetes_cluster_role_v1" "dagster_ray_ops" {
  count = local.enable_dagster ? 1 : 0

  metadata {
    name = "${local.prefix}dagster-ray-cluster-ops"
  }

  rule {
    api_groups = ["ray.io"]
    # rayjobs is the ephemeral-cluster primitive (shutdownAfterJobFinishes);
    # rayclusters is retained for hand-managed cluster lifecycles.
    # See docs/ephemeral-ray.md.
    resources = ["rayclusters", "rayclusters/status", "rayjobs", "rayjobs/status"]
    verbs     = ["get", "list", "watch", "create", "delete", "patch", "update"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "services"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "dagster_ray_ops" {
  count = local.enable_dagster ? 1 : 0

  metadata {
    name = "${local.prefix}dagster-ray-cluster-ops-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.dagster_ray_ops[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.dagster[0].metadata[0].name
    namespace = kubernetes_namespace_v1.dagster[0].metadata[0].name
  }
}

resource "kubernetes_secret_v1" "dagster_db_password" {
  count = local.enable_dagster ? 1 : 0

  metadata {
    name      = local.dagster_db_password_secret
    namespace = kubernetes_namespace_v1.dagster[0].metadata[0].name
  }

  data = {
    "postgresql-password" = var.dagster_db_password
  }
}

# Environment for the user-code deployment (and, via includeConfigInLaunchedRuns,
# every run pod). DATABASE_URL rides along automatically, as it does for the
# webapp: the assets and the app read the same database. The Secret exists
# whenever user code is deployed so the chart values can reference it
# unconditionally; an empty one is harmless.
locals {
  dagster_user_code_secret_env = merge(
    var.dagster_user_code_secret_env,
    var.database_url != "" ? { DATABASE_URL = var.database_url } : {}
  )
  dagster_user_code_env_secret = "dagster-user-code-env"
}

resource "kubernetes_secret_v1" "dagster_user_code_env" {
  count = local.enable_dagster && var.dagster_user_code_image != "" ? 1 : 0

  metadata {
    name      = local.dagster_user_code_env_secret
    namespace = kubernetes_namespace_v1.dagster[0].metadata[0].name
  }

  data = local.dagster_user_code_secret_env
}

resource "helm_release" "dagster" {
  count = local.enable_dagster ? 1 : 0

  namespace  = kubernetes_namespace_v1.dagster[0].metadata[0].name
  name       = local.dagster_release
  repository = var.dagster_repository
  chart      = "dagster"
  version    = var.dagster_chart_version
  timeout    = 600

  values = [templatefile("${local.helm_defaults}/dagster/values.yaml", {
    service_account_name    = local.dagster_service_account
    db_password_secret_name = kubernetes_secret_v1.dagster_db_password[0].metadata[0].name
    db_host                 = var.dagster_db_host
    db_user                 = var.dagster_db_user
    db_name                 = var.dagster_db_name
    user_code_image         = var.dagster_user_code_image
    user_code_env           = var.dagster_user_code_env
    user_code_env_secret    = local.dagster_user_code_env_secret
  })]

  depends_on = [
    kubernetes_service_account_v1.dagster,
    kubernetes_cluster_role_binding_v1.dagster_ray_ops,
    kubernetes_secret_v1.dagster_db_password,
    kubernetes_secret_v1.dagster_user_code_env,
  ]
}
