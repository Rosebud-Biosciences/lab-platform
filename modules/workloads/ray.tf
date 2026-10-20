# ------------------------------------------------------------------------------
# WORKLOADS MODULE - RAY (namespaced by name_prefix)
#
# Deploys the Ray namespace, the Ray ServiceAccount carrying the identity
# contract, and the environment's Ray clusters (ray_clusters), each rendered as
# a RayCluster. The KubeRay operator and its CRDs are a cluster prerequisite
# (see README). Argo Workflows, which launches RayJobs into this namespace,
# lives in argo.tf.
#
# The clusters' pods, and RayJobs launched by user code (Dagster, Argo), get
# the same contract from module-owned objects in this namespace:
#   ConfigMap analytics-config   plain env: MLFLOW_TRACKING_URI, PIPELINE_ENV,
#                                plus workload_identity["ray"].env
#   Secret    ray-identity-env   workload_identity_secret_env["ray"]
# and the ServiceAccount ray-s3-sa, which carries the SA annotations.
# ------------------------------------------------------------------------------

locals {
  ray_dashboard_service = "ray-dashboard"

  ray_clusters = var.enable_ray ? {
    for key, c in var.ray_clusters : key => merge(c, {
      name        = "${local.prefix}${key}"
      ray_version = coalesce(c.ray_version, var.ray_version)
      # A cluster on another Ray version gets that version's stock images.
      image     = coalesce(c.image, "${var.ray_image_repository}:${c.ray_version == null ? local.ray_image_tag : c.ray_version}")
      gpu_image = coalesce(c.gpu_image, "${var.ray_gpu_image_repository}:${c.ray_version == null ? local.ray_gpu_image_tag : "${c.ray_version}-gpu"}")
    })
  } : {}

  # The roles the clusters' heads and worker groups are placed by; main.tf adds
  # them to the scheduling contract.
  ray_scheduling_roles = distinct(flatten([
    for c in values(var.ray_clusters) : concat([c.head.scheduling], [for g in values(c.worker_groups) : g.scheduling])
  ]))

  ray_dashboard_cluster = coalesce(
    var.ray_dashboard_cluster_name,
    try(local.ray_clusters[sort(keys(local.ray_clusters))[0]].name, ""),
    "${local.prefix}ray-cluster",
  )

  # The two labels KubeRay's head Service selects on, so this matches that
  # cluster's head Pod and nothing else in the namespace.
  ray_head_selector = {
    "ray.io/cluster"   = local.ray_dashboard_cluster
    "ray.io/node-type" = "head"
  }

  # Ray's logs and session files (/tmp/ray) on a volume that outlives a
  # container restart.
  ray_volumes       = concat([{ name = "log-volume", emptyDir = {} }], local.identity_volumes.ray)
  ray_volume_mounts = concat([{ name = "log-volume", mountPath = "/tmp/ray" }], local.identity_volume_mounts.ray)

  ray_env_from = concat(
    [
      { configMapRef = { name = "analytics-config" } },
      { secretRef = { name = local.identity_secret_name.ray } },
    ],
    var.database_url != "" ? [{ secretRef = { name = "database-url" } }] : [],
    local.mlflow_client_credentials ? [{ secretRef = { name = "mlflow-credentials", optional = true } }] : [],
  )

  ray_placement = {
    for role in local.ray_scheduling_roles : role => merge(
      length(local.scheduling[role].node_selector) > 0 ? { nodeSelector = local.scheduling[role].node_selector } : {},
      length(local.scheduling[role].tolerations) > 0 ? { tolerations = local.scheduling[role].tolerations } : {},
    )
  }

  ray_head_start_params = {
    for key, c in local.ray_clusters : key => merge(
      c.head.num_cpus == null ? {} : { "num-cpus" = tostring(c.head.num_cpus) },
      c.head.start_params,
    )
  }

  ray_cluster_manifests = {
    for key, c in local.ray_clusters : key => {
      apiVersion = "ray.io/v1"
      kind       = "RayCluster"
      metadata = {
        name      = c.name
        namespace = local.ray_namespace
      }
      spec = merge(
        {
          rayVersion              = c.ray_version
          enableInTreeAutoscaling = true
          headGroupSpec = merge(
            length(local.ray_head_start_params[key]) > 0 ? { rayStartParams = local.ray_head_start_params[key] } : {},
            {
              template = {
                spec = merge(
                  {
                    serviceAccountName = local.ray_service_account_name
                    containers = [{
                      name            = "ray-head"
                      image           = c.image
                      imagePullPolicy = "IfNotPresent"
                      envFrom         = local.ray_env_from
                      resources       = c.head.resources
                      volumeMounts    = local.ray_volume_mounts
                    }]
                    volumes = local.ray_volumes
                  },
                  local.ray_placement[c.head.scheduling],
                )
              }
            },
          )
          # No replicas: the autoscaler sets them, and an apply that rendered
          # them would scale every group back to its minimum.
          workerGroupSpecs = [
            for group, g in c.worker_groups : merge(
              {
                groupName   = group
                minReplicas = g.min_replicas
                maxReplicas = g.max_replicas
                template = {
                  spec = merge(
                    {
                      serviceAccountName = local.ray_service_account_name
                      containers = [{
                        name            = "ray-worker"
                        image           = coalesce(g.image, contains(keys(merge(g.resources.requests, g.resources.limits)), "nvidia.com/gpu") ? c.gpu_image : c.image)
                        imagePullPolicy = "IfNotPresent"
                        envFrom         = local.ray_env_from
                        resources       = g.resources
                        volumeMounts    = local.ray_volume_mounts
                      }]
                      volumes = local.ray_volumes
                    },
                    local.ray_placement[g.scheduling],
                  )
                }
              },
              length(g.start_params) > 0 ? { rayStartParams = g.start_params } : {},
            )
          ]
        },
        c.autoscaler_resources == null ? {} : {
          autoscalerOptions = { resources = { for k, v in c.autoscaler_resources : k => v if v != null } }
        },
      )
    }
  }
}

resource "kubernetes_namespace_v1" "ray" {
  count = var.enable_ray ? 1 : 0

  metadata {
    name = local.namespace_names.ray
    # NetworkPolicies admit client services by this label (netpol.tf).
    labels = merge({ "lab-platform.io/service" = "ray" }, local.tenant_labels)
  }
}

resource "kubernetes_service_account_v1" "ray_cluster_sa" {
  count = var.enable_ray ? 1 : 0

  metadata {
    name        = local.ray_service_account_name
    namespace   = local.ray_namespace
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
    namespace = local.ray_namespace
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
    namespace = local.ray_namespace
  }

  data = local.identity_secret_env.ray
}

resource "kubernetes_secret_v1" "database_url" {
  count = var.enable_ray && var.database_url != "" ? 1 : 0

  metadata {
    name      = "database-url"
    namespace = local.ray_namespace
  }

  data = {
    DATABASE_URL = var.database_url
  }
}

# ------------------------------------------------------------------------------
# Ray clusters (ray_clusters)
# ------------------------------------------------------------------------------

resource "kubectl_manifest" "ray_cluster" {
  for_each = local.ray_cluster_manifests

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  # A cluster that the ray-cluster Helm release created has its fields owned
  # by Helm.
  force_conflicts = true
  wait            = true

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", each.value.metadata.name))
      error_message = "RayCluster name ${each.value.metadata.name} (name_prefix + ray_clusters key) must start with a letter: KubeRay requires a DNS-1035 label."
    }
  }

  depends_on = [
    kubernetes_service_account_v1.ray_cluster_sa,
    kubernetes_config_map_v1.analytics_config,
    kubernetes_secret_v1.ray_identity_env,
    kubernetes_secret_v1.database_url,
  ]
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
    namespace = local.ray_namespace
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
