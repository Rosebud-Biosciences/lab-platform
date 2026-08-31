# ------------------------------------------------------------------------------
# WORKLOADS MODULE - PRIVATE INGRESSES
#
# Per-workload Ingresses on a configurable private IngressClass
# (var.private_ingress_class_name, default "tailscale" for the operator from the
# platform module). Hostnames are prefix-unique so previews get their own
# https://<prefix>dagster.<suffix>. Bring your own controller by pointing the
# class name at it.
# ------------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "dagster_private" {
  count = var.enable_private_ingress && local.enable_dagster ? 1 : 0

  metadata {
    name      = "dagster-private"
    namespace = local.dagster_namespace
  }

  spec {
    ingress_class_name = var.private_ingress_class_name

    default_backend {
      service {
        name = local.dagster_webserver_service
        port {
          number = 80
        }
      }
    }

    tls {
      hosts = [local.private_dagster_host]
    }
  }

  depends_on = [helm_release.dagster]
}

resource "kubernetes_ingress_v1" "mlflow_private" {
  count = var.enable_private_ingress && var.enable_mlflow ? 1 : 0

  metadata {
    name      = "mlflow-private"
    namespace = local.mlflow_namespace
  }

  spec {
    ingress_class_name = var.private_ingress_class_name

    default_backend {
      service {
        name = local.mlflow_service
        port {
          number = 80
        }
      }
    }

    tls {
      hosts = [local.private_mlflow_host]
    }
  }

  depends_on = [helm_release.mlflow]
}

resource "kubernetes_ingress_v1" "webapp_private" {
  count = var.enable_private_ingress && var.enable_webapp ? 1 : 0

  metadata {
    name      = "${var.webapp_app_name}-private"
    namespace = local.webapp_namespace
  }

  spec {
    ingress_class_name = var.private_ingress_class_name

    default_backend {
      service {
        name = var.webapp_app_name
        port {
          number = 80
        }
      }
    }

    tls {
      hosts = [local.private_webapp_host]
    }
  }

  depends_on = [kubernetes_service_v1.webapp]
}

resource "kubernetes_ingress_v1" "ray_dashboard_private" {
  count = var.enable_private_ingress && var.enable_ray ? 1 : 0

  metadata {
    name      = "ray-dashboard-private"
    namespace = local.ray_namespace
  }

  spec {
    ingress_class_name = var.private_ingress_class_name

    default_backend {
      service {
        name = local.ray_dashboard_service
        port {
          number = 80
        }
      }
    }

    tls {
      hosts = [local.private_ray_host]
    }
  }

  depends_on = [kubernetes_service_v1.ray_dashboard]
}
