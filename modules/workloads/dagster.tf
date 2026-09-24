# ------------------------------------------------------------------------------
# WORKLOADS MODULE - DAGSTER CONTROL PLANE (namespaced by name_prefix)
#
# Deploys the official dagster/dagster Helm chart against an external Postgres,
# with a ServiceAccount carrying the identity contract and RBAC to manage Ray
# clusters in the ray namespace. Requires enable_ray = true (enforced by the
# precondition below).
# ------------------------------------------------------------------------------

locals {
  dagster_db_password_secret = "dagster-postgresql-secret"
}

resource "kubernetes_namespace_v1" "dagster" {
  count = local.enable_dagster ? 1 : 0

  metadata {
    name = local.dagster_namespace
    # NetworkPolicies admit client services by this label (netpol.tf).
    labels = merge({ "lab-platform.io/service" = "dagster" }, local.tenant_labels)
  }

  lifecycle {
    precondition {
      condition     = var.enable_ray
      error_message = "enable_dagster = true requires enable_ray = true (Dagster launches runs against the Ray namespace)."
    }
  }
}

resource "kubernetes_service_account_v1" "dagster" {
  count = local.enable_dagster ? 1 : 0

  metadata {
    name        = local.dagster_service_account
    namespace   = kubernetes_namespace_v1.dagster[0].metadata[0].name
    annotations = local.identity.dagster.service_account_annotations
  }
}

# RBAC so Dagster runs can create/delete Ray clusters in this environment's Ray
# namespace -- only there: a RayCluster's pods may name any ServiceAccount of
# the namespace they run in, so the right to create one anywhere else would be
# the right to run as another environment's identity.
resource "kubernetes_role_v1" "dagster_ray_ops" {
  count = local.enable_dagster && var.enable_ray ? 1 : 0

  metadata {
    name      = "${local.prefix}dagster-ray-cluster-ops"
    namespace = kubernetes_namespace_v1.ray[0].metadata[0].name
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

resource "kubernetes_role_binding_v1" "dagster_ray_ops" {
  count = local.enable_dagster && var.enable_ray ? 1 : 0

  metadata {
    name      = "${local.prefix}dagster-ray-cluster-ops"
    namespace = kubernetes_namespace_v1.ray[0].metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.dagster_ray_ops[0].metadata[0].name
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

# Identity contract: static credentials for every Dagster pod (webserver,
# daemon, user code, launched runs). Exists even when empty so the chart values
# can reference it unconditionally.
resource "kubernetes_secret_v1" "dagster_identity_env" {
  count = local.enable_dagster ? 1 : 0

  metadata {
    name      = local.identity_secret_name.dagster
    namespace = kubernetes_namespace_v1.dagster[0].metadata[0].name
  }

  data = local.identity_secret_env.dagster
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

# No user-code image: the module's own hello-world code location, mounted from
# this ConfigMap into the stock dagster-k8s image, so a fresh platform has an
# asset to materialize without depending on upstream's example image.
locals {
  dagster_hello_code = local.enable_dagster && var.dagster_user_code_image == ""
  dagster_hello_cm   = "dagster-hello-code"

  dagster_user_code_volumes = concat(
    local.identity_volumes.dagster,
    local.dagster_hello_code ? [{ name = "code", configMap = { name = local.dagster_hello_cm } }] : [],
  )
  dagster_user_code_volume_mounts = concat(
    local.identity_volume_mounts.dagster,
    local.dagster_hello_code ? [{ name = "code", mountPath = "/opt/dagster/app", readOnly = true }] : [],
  )
}

locals {
  dagster_default_location = {
    name = var.dagster_user_code_image != "" ? "user-code" : "hello"
    image = var.dagster_user_code_image != "" ? local.dagster_default_image : {
      repository = "dagster/dagster-k8s"
      tag        = var.dagster_chart_version
      pullPolicy = "IfNotPresent"
    }
    dagsterApiGrpcArgs = ["--python-file", "/opt/dagster/app/repo.py"]
    port               = 3030
    serviceAccountName = local.dagster_service_account
    # Plain values inline (identity contract + caller's); secrets
    # (DATABASE_URL, the caller's, the identity contract's static
    # credentials, MLflow's service-account token) from Secrets. All reach
    # launched run pods as well (includeConfigInLaunchedRuns).
    env = merge(local.identity.dagster.env, local.service_urls_env, var.dagster_user_code_env)
    envSecrets = concat(
      var.dagster_user_code_image != "" ? [{ name = local.dagster_user_code_env_secret }] : [],
      [{ name = local.identity_secret_name.dagster }],
      local.mlflow_client_credentials ? [{ name = "mlflow-credentials" }] : [],
    )
    volumes      = local.dagster_user_code_volumes
    volumeMounts = local.dagster_user_code_volume_mounts
    nodeSelector = local.scheduling.dagster.node_selector
    tolerations  = local.scheduling.dagster.tolerations
  }
}

resource "kubernetes_config_map_v1" "dagster_hello_code" {
  count = local.dagster_hello_code ? 1 : 0

  metadata {
    name      = local.dagster_hello_cm
    namespace = kubernetes_namespace_v1.dagster[0].metadata[0].name
  }

  data = {
    "repo.py" = file("${local.helm_defaults}/dagster/hello_repo.py")
  }
}

resource "helm_release" "dagster" {
  count = local.enable_dagster ? 1 : 0

  namespace  = kubernetes_namespace_v1.dagster[0].metadata[0].name
  name       = local.dagster_release
  repository = var.dagster_repository
  chart      = "dagster"
  version    = var.dagster_chart_version
  timeout    = 600
  wait       = var.wait_for_rollouts

  values = [templatefile("${local.helm_defaults}/dagster/values.yaml", {
    service_account_name    = local.dagster_service_account
    db_password_secret_name = kubernetes_secret_v1.dagster_db_password[0].metadata[0].name
    db_host                 = var.dagster_db_host
    db_user                 = var.dagster_db_user
    db_name                 = var.dagster_db_name
    user_deployments        = jsonencode(concat([local.dagster_default_location], local.dagster_extra_locations))
    identity_env_secret     = kubernetes_secret_v1.dagster_identity_env[0].metadata[0].name
    identity_env            = jsonencode(local.identity_env_list.dagster)
    identity_volumes        = jsonencode(local.identity_volumes.dagster)
    identity_volume_mounts  = jsonencode(local.identity_volume_mounts.dagster)
    node_selector           = jsonencode(local.scheduling.dagster.node_selector)
    tolerations             = jsonencode(local.scheduling.dagster.tolerations)
  })]

  depends_on = [
    kubernetes_service_account_v1.dagster,
    kubernetes_role_binding_v1.dagster_ray_ops,
    kubernetes_secret_v1.dagster_db_password,
    kubernetes_secret_v1.dagster_identity_env,
    kubernetes_secret_v1.dagster_user_code_env,
    kubernetes_config_map_v1.dagster_hello_code,
  ]
}
