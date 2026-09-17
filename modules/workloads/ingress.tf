# ------------------------------------------------------------------------------
# WORKLOADS MODULE - PRIVATE INGRESSES
#
# Per-workload Ingresses on a configurable private IngressClass
# (var.private_ingress_class_name, default "tailscale" for the operator from the
# platform module). Hostnames are prefix-unique so previews get their own
# https://<prefix>dagster.<suffix>. Bring your own controller by pointing the
# class name at it. var.private_ingress_annotations decorates each Ingress
# (per service or "*" for all) -- see that variable for the Tailscale ACL
# device-tag scoping it exists for.
# ------------------------------------------------------------------------------

locals {
  private_ingress_annotations = {
    for svc in ["dagster", "mlflow", "webapp", "ray", "argo"] :
    svc => merge(
      lookup(var.private_ingress_annotations, "*", {}),
      lookup(var.private_ingress_annotations, svc, {}),
    )
  }
}

resource "kubernetes_ingress_v1" "dagster_private" {
  count = var.enable_private_ingress && local.enable_dagster ? 1 : 0

  metadata {
    name        = "dagster-private"
    namespace   = local.dagster_namespace
    annotations = local.private_ingress_annotations.dagster
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
    name        = "mlflow-private"
    namespace   = local.mlflow_namespace
    annotations = local.private_ingress_annotations.mlflow
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
    name        = "${var.webapp_app_name}-private"
    namespace   = local.webapp_namespace
    annotations = local.private_ingress_annotations.webapp
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
    name        = "ray-dashboard-private"
    namespace   = local.ray_namespace
    annotations = local.private_ingress_annotations.ray
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

resource "kubernetes_ingress_v1" "argo_private" {
  count = var.enable_private_ingress && var.enable_argo_workflows ? 1 : 0

  metadata {
    name        = "argo-private"
    namespace   = local.argo_namespace
    annotations = local.private_ingress_annotations.argo
  }

  spec {
    ingress_class_name = var.private_ingress_class_name

    default_backend {
      service {
        name = local.argo_server_service
        port {
          number = 2746
        }
      }
    }

    tls {
      hosts = [local.private_argo_host]
    }
  }

  depends_on = [helm_release.argo_workflows]
}
