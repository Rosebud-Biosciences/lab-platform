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
#
# auth = { mode = "oidc" }: a protected service's Ingress points at its
# oauth2-proxy Service (auth.tf) instead of the service itself, so the login
# happens before any request reaches the UI, whatever the IngressClass.
# ------------------------------------------------------------------------------

locals {
  private_ingress_annotations = {
    for svc in ["dagster", "mlflow", "webapp", "ray", "argo"] :
    svc => merge(
      lookup(var.private_ingress_annotations, "*", {}),
      lookup(var.private_ingress_annotations, svc, {}),
    )
  }

  # Backend per service: the oauth2-proxy when protected, the service otherwise.
  private_backend = {
    for svc, up in local.proxy_upstream :
    svc => contains(keys(local.proxied_services), svc) ? { name = local.proxy_service_name[svc], port = 80 } : { name = up.service, port = up.port }
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
        name = local.private_backend.dagster.name
        port {
          number = local.private_backend.dagster.port
        }
      }
    }

    tls {
      hosts = [local.private_dagster_host]
    }
  }

  depends_on = [helm_release.dagster, kubernetes_service_v1.oauth2_proxy]
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
        name = local.private_backend.mlflow.name
        port {
          number = local.private_backend.mlflow.port
        }
      }
    }

    tls {
      hosts = [local.private_mlflow_host]
    }
  }

  depends_on = [helm_release.mlflow, kubernetes_service_v1.oauth2_proxy]
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
        name = local.private_backend.webapp.name
        port {
          number = local.private_backend.webapp.port
        }
      }
    }

    tls {
      hosts = [local.private_webapp_host]
    }
  }

  depends_on = [kubernetes_service_v1.webapp, kubernetes_service_v1.oauth2_proxy]
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
        name = local.private_backend.ray.name
        port {
          number = local.private_backend.ray.port
        }
      }
    }

    tls {
      hosts = [local.private_ray_host]
    }
  }

  depends_on = [kubernetes_service_v1.ray_dashboard, kubernetes_service_v1.oauth2_proxy]
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
