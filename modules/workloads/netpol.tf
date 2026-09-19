# ------------------------------------------------------------------------------
# WORKLOADS MODULE - NETWORK POLICIES (var.network_policies)
#
# The UIs' gates -- the Tailscale Ingress in "headers" mode, an oauth2-proxy in
# "oidc" mode -- only mean something if they are the way in. Dagster, MLflow
# and the Ray dashboard have no login of their own, and the webapp trusts an
# identity header in "headers" mode, so without a fence any pod in the
# cluster (a notebook, a PR's code in a preview) could go around the gate.
# Per service namespace:
#
#   <svc>-upstream   the service's pods (everything but its proxy) accept
#                    traffic from their own namespace, from the namespaces of
#                    the services that legitimately call them (clients, by
#                    the lab-platform.io/service label, in any environment),
#                    from extra_namespaces (e.g. the KubeRay operator), and --
#                    only when the service is NOT proxied -- from the ingress
#                    controller's namespaces.
#   <svc>-front-door the oauth2-proxy pods accept traffic only from the
#                    ingress controller's namespaces.
#
# Clients are matched by label, not name, so an app-only preview's webapp can
# still reach prod's Dagster (the documented stamp-or-share trade-off). A
# NetworkPolicy is inert unless the CNI enforces it: kind's kindnet does; on
# EKS enable the VPC CNI's policy agent (aws/eks-platform
# enable_network_policy).
# ------------------------------------------------------------------------------

locals {
  netpol_default_clients = {
    webapp  = []
    dagster = ["webapp"]
    mlflow  = ["webapp", "dagster", "ray", "argo", "jupyterhub"]
    ray     = ["dagster", "argo"]
    argo    = ["webapp"]
  }
  netpol_default_namespaces = {
    webapp  = []
    dagster = []
    mlflow  = []
    ray     = ["kuberay-system"] # the operator polls the head's dashboard for RayJob status
    argo    = []
  }

  netpol_service_namespace = {
    webapp  = local.webapp_namespace
    dagster = local.dagster_namespace
    mlflow  = local.mlflow_namespace
    ray     = local.ray_namespace
    argo    = local.argo_namespace
  }

  netpol_services = {
    for svc, on in {
      webapp  = var.enable_webapp
      dagster = local.enable_dagster
      mlflow  = var.enable_mlflow
      ray     = var.enable_ray
      argo    = var.enable_argo_workflows
      } : svc => {
      namespace  = local.netpol_service_namespace[svc]
      clients    = lookup(var.network_policies.clients, svc, local.netpol_default_clients[svc])
      namespaces = lookup(var.network_policies.extra_namespaces, svc, local.netpol_default_namespaces[svc])
      proxied    = contains(keys(local.proxied_services), svc)
      # A public webapp's front door is the internet (its load balancer).
      public = svc == "webapp" && local.webapp_public_enabled
    } if var.network_policies.enabled && on
  }
}

resource "kubernetes_network_policy_v1" "upstream" {
  for_each = local.netpol_services

  metadata {
    name      = "${each.key}-upstream"
    namespace = each.value.namespace
  }

  spec {
    pod_selector {
      match_expressions {
        key      = "app"
        operator = "NotIn"
        values   = ["${each.key}-auth"]
      }
    }
    policy_types = ["Ingress"]

    ingress {
      # Its own namespace: the proxy, daemons, run pods, workers.
      from {
        pod_selector {}
      }

      dynamic "from" {
        for_each = length(each.value.clients) > 0 ? [each.value.clients] : []
        content {
          namespace_selector {
            match_expressions {
              key      = "lab-platform.io/service"
              operator = "In"
              values   = from.value
            }
          }
        }
      }

      dynamic "from" {
        for_each = length(each.value.namespaces) > 0 ? [each.value.namespaces] : []
        content {
          namespace_selector {
            match_expressions {
              key      = "kubernetes.io/metadata.name"
              operator = "In"
              values   = from.value
            }
          }
        }
      }

      dynamic "from" {
        for_each = !each.value.proxied && length(var.network_policies.ingress_namespaces) > 0 ? [var.network_policies.ingress_namespaces] : []
        content {
          namespace_selector {
            match_expressions {
              key      = "kubernetes.io/metadata.name"
              operator = "In"
              values   = from.value
            }
          }
        }
      }

      dynamic "from" {
        for_each = each.value.public ? [1] : []
        content {
          ip_block {
            cidr = "0.0.0.0/0"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace_v1.webapp,
    kubernetes_namespace_v1.dagster,
    kubernetes_namespace_v1.mlflow,
    kubernetes_namespace_v1.ray,
    kubernetes_namespace_v1.argo,
  ]
}

resource "kubernetes_network_policy_v1" "front_door" {
  for_each = { for svc, v in local.netpol_services : svc => v if v.proxied }

  metadata {
    name      = "${each.key}-front-door"
    namespace = each.value.namespace
  }

  spec {
    pod_selector {
      match_labels = { app = "${each.key}-auth" }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_expressions {
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = var.network_policies.ingress_namespaces
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.network_policies.ingress_namespaces) > 0
      error_message = "network_policies.ingress_namespaces is empty, so nothing could reach ${each.key}'s login proxy: name the ingress controller's namespace(s)."
    }
  }

  depends_on = [kubernetes_deployment_v1.oauth2_proxy]
}
