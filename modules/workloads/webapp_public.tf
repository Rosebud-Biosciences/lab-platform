# ------------------------------------------------------------------------------
# WORKLOADS MODULE - WEBAPP PUBLIC SURFACE (internet-facing Ingress + autoscaling)
#
# Gated on enable_webapp_public_ingress (default OFF). When on, adds:
#   - an Ingress on the caller's public IngressClass, decorated with the
#     caller's annotations (aws/compute-adapter: ALB scheme, ACM certificate,
#     WAF ACL; ingress-nginx: cert-manager issuer), optionally with a TLS
#     Secret, and stamped with the external-dns hostname annotation so DNS
#     follows the Ingress wherever external-dns runs
#   - an HPA (scales with load) and a PodDisruptionBudget (safe rollouts/drains)
#
# Set webapp_ignore_image_changes = true so a re-apply does not fight the HPA
# over the replica count.
# ------------------------------------------------------------------------------

locals {
  webapp_public_enabled      = var.enable_webapp && var.enable_webapp_public_ingress
  webapp_public_ingress_name = "${var.webapp_app_name}-public"

  webapp_public_annotations = merge(
    var.webapp_public_host != "" ? { "external-dns.alpha.kubernetes.io/hostname" = var.webapp_public_host } : {},
    var.webapp_public_ingress_annotations,
  )
}

resource "kubernetes_ingress_v1" "webapp_public" {
  count = local.webapp_public_enabled ? 1 : 0

  metadata {
    name        = local.webapp_public_ingress_name
    namespace   = local.webapp_namespace
    annotations = local.webapp_public_annotations
  }

  spec {
    ingress_class_name = var.webapp_public_ingress_class_name

    dynamic "tls" {
      for_each = var.webapp_public_tls_secret_name != "" ? [1] : []
      content {
        hosts       = [var.webapp_public_host]
        secret_name = var.webapp_public_tls_secret_name
      }
    }

    rule {
      host = var.webapp_public_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = var.webapp_app_name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  wait_for_load_balancer = var.webapp_public_wait_for_load_balancer

  depends_on = [kubernetes_service_v1.webapp]
}

# ------------------------------------------------------------------------------
# Autoscaling + availability
# ------------------------------------------------------------------------------

resource "kubernetes_horizontal_pod_autoscaler_v2" "webapp" {
  count = local.webapp_public_enabled ? 1 : 0

  metadata {
    name      = var.webapp_app_name
    namespace = local.webapp_namespace
  }

  spec {
    min_replicas = var.webapp_hpa_min_replicas
    max_replicas = var.webapp_hpa_max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = var.webapp_app_name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.webapp_hpa_cpu_target
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment_v1.webapp,
    kubernetes_deployment_v1.webapp_pinned,
  ]
}

resource "kubernetes_pod_disruption_budget_v1" "webapp" {
  count = local.webapp_public_enabled ? 1 : 0

  metadata {
    name      = var.webapp_app_name
    namespace = local.webapp_namespace
  }

  spec {
    min_available = 1
    selector {
      match_labels = local.webapp_labels
    }
  }
}
