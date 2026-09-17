# ------------------------------------------------------------------------------
# WORKLOADS MODULE - WEBAPP (generic web application, namespaced by name_prefix)
#
# A single-container Deployment + Service + ServiceAccount, with configurable
# plain and secret env (plus the service URLs: MLFLOW_TRACKING_URI,
# DAGSTER_WEBSERVER_URL, ARGO_SERVER_URL -- stamped here or shared, see
# main.tf), optional Service-level session affinity, and (in webapp_public.tf)
# an optional internet-facing Ingress with HPA/PDB.
# Cloud identity arrives through the workload_identity contract: SA
# annotations, env, a projected token volume, and/or static secret env.
# ------------------------------------------------------------------------------

locals {
  webapp_labels = { app = var.webapp_app_name }

  webapp_effective_replicas = var.webapp_replicas

  # Plain env: caller-supplied plus the identity contract's (region, role ARN,
  # token path, endpoint URL).
  webapp_plain_env = merge(local.identity.webapp.env, local.service_urls_env, var.webapp_env)
}

resource "kubernetes_namespace_v1" "webapp" {
  count = var.enable_webapp ? 1 : 0

  metadata {
    name = local.webapp_namespace
  }
}

resource "kubernetes_service_account_v1" "webapp" {
  count = var.enable_webapp ? 1 : 0

  metadata {
    name        = local.webapp_service_account_name
    namespace   = kubernetes_namespace_v1.webapp[0].metadata[0].name
    annotations = local.identity.webapp.service_account_annotations
  }
}

# Secret env: caller-supplied secret values (e.g. session secret, OIDC client
# secret), the identity contract's static credentials, plus the shared
# DATABASE_URL when set. Injected via envFrom.
resource "kubernetes_secret_v1" "webapp_env" {
  count = var.enable_webapp ? 1 : 0

  metadata {
    name      = "${var.webapp_app_name}-env"
    namespace = kubernetes_namespace_v1.webapp[0].metadata[0].name
  }

  data = merge(
    local.identity_secret_env.webapp,
    var.webapp_secret_env,
    var.database_url != "" ? { DATABASE_URL = var.database_url } : {}
  )
}

# Terraform-managed Deployment (previews / IaC-owned image + replicas).
resource "kubernetes_deployment_v1" "webapp" {
  count = var.enable_webapp && !var.webapp_ignore_image_changes ? 1 : 0

  metadata {
    name      = var.webapp_app_name
    namespace = kubernetes_namespace_v1.webapp[0].metadata[0].name
    labels    = local.webapp_labels
  }

  spec {
    replicas = local.webapp_effective_replicas

    selector {
      match_labels = local.webapp_labels
    }

    template {
      metadata {
        labels = local.webapp_labels
      }

      spec {
        service_account_name = kubernetes_service_account_v1.webapp[0].metadata[0].name
        node_selector        = local.scheduling.webapp.node_selector

        dynamic "toleration" {
          for_each = local.scheduling.webapp.tolerations
          content {
            key      = lookup(toleration.value, "key", null)
            operator = lookup(toleration.value, "operator", null)
            value    = lookup(toleration.value, "value", null)
            effect   = lookup(toleration.value, "effect", null)
          }
        }

        dynamic "volume" {
          for_each = local.identity_volumes.webapp
          content {
            name = volume.value.name
            projected {
              sources {
                service_account_token {
                  audience           = volume.value.projected.sources[0].serviceAccountToken.audience
                  expiration_seconds = volume.value.projected.sources[0].serviceAccountToken.expirationSeconds
                  path               = volume.value.projected.sources[0].serviceAccountToken.path
                }
              }
            }
          }
        }

        container {
          name  = var.webapp_app_name
          image = var.webapp_image

          port {
            container_port = var.webapp_container_port
          }

          dynamic "env" {
            for_each = local.webapp_plain_env
            content {
              name  = env.key
              value = env.value
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.webapp_env[0].metadata[0].name
            }
          }

          dynamic "volume_mount" {
            for_each = local.identity_volume_mounts.webapp
            content {
              name       = volume_mount.value.name
              mount_path = volume_mount.value.mountPath
              read_only  = volume_mount.value.readOnly
            }
          }

          readiness_probe {
            http_get {
              path = var.webapp_health_check_path
              port = var.webapp_container_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = var.webapp_health_check_path
              port = var.webapp_container_port
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = var.webapp_cpu_request
              memory = var.webapp_memory_request
            }
            limits = {
              memory = var.webapp_memory_limit
            }
          }
        }
      }
    }
  }
}

# CI-owned twin: IDENTICAL pod spec, but ignores the container image so an
# external CI (kubectl set image) owns the running tag, and the replica count so
# a re-apply never fights the HPA. Terraform cannot express a conditional
# lifecycle block, so the two variants are mutually exclusive via count. KEEP
# THE POD SPEC IN SYNC with kubernetes_deployment_v1.webapp above.
resource "kubernetes_deployment_v1" "webapp_pinned" {
  count = var.enable_webapp && var.webapp_ignore_image_changes ? 1 : 0

  metadata {
    name      = var.webapp_app_name
    namespace = kubernetes_namespace_v1.webapp[0].metadata[0].name
    labels    = local.webapp_labels
  }

  spec {
    replicas = local.webapp_effective_replicas

    selector {
      match_labels = local.webapp_labels
    }

    template {
      metadata {
        labels = local.webapp_labels
      }

      spec {
        service_account_name = kubernetes_service_account_v1.webapp[0].metadata[0].name
        node_selector        = local.scheduling.webapp.node_selector

        dynamic "toleration" {
          for_each = local.scheduling.webapp.tolerations
          content {
            key      = lookup(toleration.value, "key", null)
            operator = lookup(toleration.value, "operator", null)
            value    = lookup(toleration.value, "value", null)
            effect   = lookup(toleration.value, "effect", null)
          }
        }

        dynamic "volume" {
          for_each = local.identity_volumes.webapp
          content {
            name = volume.value.name
            projected {
              sources {
                service_account_token {
                  audience           = volume.value.projected.sources[0].serviceAccountToken.audience
                  expiration_seconds = volume.value.projected.sources[0].serviceAccountToken.expirationSeconds
                  path               = volume.value.projected.sources[0].serviceAccountToken.path
                }
              }
            }
          }
        }

        container {
          name  = var.webapp_app_name
          image = var.webapp_image

          port {
            container_port = var.webapp_container_port
          }

          dynamic "env" {
            for_each = local.webapp_plain_env
            content {
              name  = env.key
              value = env.value
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.webapp_env[0].metadata[0].name
            }
          }

          dynamic "volume_mount" {
            for_each = local.identity_volume_mounts.webapp
            content {
              name       = volume_mount.value.name
              mount_path = volume_mount.value.mountPath
              read_only  = volume_mount.value.readOnly
            }
          }

          readiness_probe {
            http_get {
              path = var.webapp_health_check_path
              port = var.webapp_container_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = var.webapp_health_check_path
              port = var.webapp_container_port
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = var.webapp_cpu_request
              memory = var.webapp_memory_request
            }
            limits = {
              memory = var.webapp_memory_limit
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image,
      spec[0].replicas,
    ]
  }
}

resource "kubernetes_service_v1" "webapp" {
  count = var.enable_webapp ? 1 : 0

  metadata {
    name      = var.webapp_app_name
    namespace = kubernetes_namespace_v1.webapp[0].metadata[0].name
    labels    = local.webapp_labels
  }

  spec {
    selector = local.webapp_labels

    port {
      port        = 80
      target_port = var.webapp_container_port
    }

    type = "ClusterIP"

    # Optional ClientIP affinity for stateful single-pod sessions routed through
    # the Service (e.g. the private ingress path). 0 disables.
    session_affinity = var.webapp_session_affinity_seconds > 0 ? "ClientIP" : "None"

    dynamic "session_affinity_config" {
      for_each = var.webapp_session_affinity_seconds > 0 ? [1] : []
      content {
        client_ip {
          timeout_seconds = var.webapp_session_affinity_seconds
        }
      }
    }
  }
}
