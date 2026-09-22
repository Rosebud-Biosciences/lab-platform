# ------------------------------------------------------------------------------
# WORKLOADS MODULE - RAY (namespaced by name_prefix)
#
# Deploys the Ray namespace, the Ray ServiceAccount carrying the identity
# contract, and an optional persistent Ray cluster (KubeRay ray-cluster chart).
# The KubeRay operator is a cluster prerequisite (see README). Argo Workflows,
# which launches RayJobs into this namespace, lives in argo.tf.
#
# RayJobs launched by user code (Dagster, Argo) build their own pod specs; two
# module-owned objects give them a stable contract in this namespace:
#   ConfigMap analytics-config   plain env: MLFLOW_TRACKING_URI, PIPELINE_ENV,
#                                plus workload_identity["ray"].env
#   Secret    ray-identity-env   workload_identity_secret_env["ray"]
# and the ServiceAccount ray-s3-sa, which carries the SA annotations.
# ------------------------------------------------------------------------------

locals {
  ray_dashboard_service = "ray-dashboard"

  ray_dashboard_cluster = var.ray_dashboard_cluster_name != "" ? var.ray_dashboard_cluster_name : "${local.prefix}${var.ray_cluster_release_name}"

  # The two labels KubeRay's head Service selects on, so this matches that
  # cluster's head Pod and nothing else in the namespace.
  ray_head_selector = {
    "ray.io/cluster"   = local.ray_dashboard_cluster
    "ray.io/node-type" = "head"
  }

  # The chart's own log volume must stay when we set volumes/volumeMounts.
  ray_log_volume       = [{ name = "log-volume", emptyDir = {} }]
  ray_log_volume_mount = [{ name = "log-volume", mountPath = "/tmp/ray" }]
}

resource "kubernetes_namespace_v1" "ray" {
  count = var.enable_ray ? 1 : 0

  metadata {
    name = local.ray_namespace
    # NetworkPolicies admit client services by this label (netpol.tf).
    labels = merge({ "lab-platform.io/service" = "ray" }, local.tenant_labels)
  }
}

resource "kubernetes_service_account_v1" "ray_cluster_sa" {
  count = var.enable_ray ? 1 : 0

  metadata {
    name        = local.ray_service_account_name
    namespace   = kubernetes_namespace_v1.ray[0].metadata[0].name
    annotations = local.identity.ray.service_account_annotations
  }

  automount_service_account_token = true
}

# Shared analytics env for pipeline compute: the service URLs (MLflow tracking,
# Dagster, Argo -- stamped or shared), the environment name, and the identity
# contract's plain env (region, endpoint URL, role ARN).
resource "kubernetes_config_map_v1" "analytics_config" {
  count = var.enable_ray ? 1 : 0

  metadata {
    name      = "analytics-config"
    namespace = kubernetes_namespace_v1.ray[0].metadata[0].name
  }

  data = merge(
    local.identity.ray.env,
    local.service_urls_env,
    { "PIPELINE_ENV" = var.environment },
  )
}

resource "kubernetes_secret_v1" "ray_identity_env" {
  count = var.enable_ray ? 1 : 0

  metadata {
    name      = local.identity_secret_name.ray
    namespace = kubernetes_namespace_v1.ray[0].metadata[0].name
  }

  data = local.identity_secret_env.ray
}

resource "kubernetes_secret_v1" "database_url" {
  count = var.enable_ray && var.database_url != "" ? 1 : 0

  metadata {
    name      = "database-url"
    namespace = kubernetes_namespace_v1.ray[0].metadata[0].name
  }

  data = {
    DATABASE_URL = var.database_url
  }
}

# ------------------------------------------------------------------------------
# Persistent Ray cluster (optional)
# ------------------------------------------------------------------------------

resource "helm_release" "ray_cluster" {
  count = var.enable_ray && var.enable_ray_cluster ? 1 : 0

  namespace  = kubernetes_namespace_v1.ray[0].metadata[0].name
  name       = "${local.prefix}${var.ray_cluster_release_name}"
  repository = var.ray_cluster_repository
  chart      = "ray-cluster"
  version    = var.ray_cluster_chart_version
  timeout    = 600

  values = [templatefile("${local.helm_defaults}/ray/values.yaml", {
    cluster_name            = "${local.prefix}${var.ray_cluster_release_name}"
    image_repo              = var.ray_image_repository
    image_tag               = local.ray_image_tag
    ray_version             = var.ray_version
    ray_single_user_sa_name = kubernetes_service_account_v1.ray_cluster_sa[0].metadata[0].name
    gpu_image_repo          = var.ray_gpu_image_repository
    gpu_image_tag           = local.ray_gpu_image_tag
    head_resources          = jsonencode(var.ray_head_resources)
    worker_resources        = jsonencode(var.ray_worker_resources)
    worker_max_replicas     = var.ray_worker_max_replicas
    enable_autoscaler       = var.ray_enable_autoscaler
    mlflow_credentials      = local.mlflow_client_credentials
    head_start_params = jsonencode(merge(
      var.ray_head_num_cpus == null ? {} : { "num-cpus" = tostring(var.ray_head_num_cpus) },
      var.ray_head_start_params,
    ))
    identity_env         = jsonencode(local.identity_env_list.ray)
    identity_env_secret  = kubernetes_secret_v1.ray_identity_env[0].metadata[0].name
    volumes              = jsonencode(concat(local.ray_log_volume, local.identity_volumes.ray))
    volume_mounts        = jsonencode(concat(local.ray_log_volume_mount, local.identity_volume_mounts.ray))
    head_node_selector   = jsonencode(local.scheduling.ray_head.node_selector)
    head_tolerations     = jsonencode(local.scheduling.ray_head.tolerations)
    worker_node_selector = jsonencode(local.scheduling.ray_worker.node_selector)
    worker_tolerations   = jsonencode(local.scheduling.ray_worker.tolerations)
  })]

  depends_on = [kubernetes_secret_v1.ray_identity_env]
}

# ------------------------------------------------------------------------------
# RAY DASHBOARD SERVICE (stable backend for the private Ingress)
#
# A Terraform-owned ClusterIP Service so the private hostname stays put across
# the create/delete cycle of the RayCluster itself; the selector picks up
# whichever head Pod is currently up (502s while none is running).
# ------------------------------------------------------------------------------

resource "kubernetes_service_v1" "ray_dashboard" {
  # Also the upstream of the dashboard's oauth2-proxy (auth.tf), which may run
  # without a private Ingress (kind).
  count = var.enable_ray && (var.enable_private_ingress || contains(keys(local.proxied_services), "ray")) ? 1 : 0

  metadata {
    name      = local.ray_dashboard_service
    namespace = kubernetes_namespace_v1.ray[0].metadata[0].name
  }

  spec {
    selector = local.ray_head_selector

    port {
      name        = "dashboard"
      port        = 80
      target_port = 8265
    }

    type = "ClusterIP"
  }
}
