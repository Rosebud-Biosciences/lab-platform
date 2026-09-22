# ------------------------------------------------------------------------------
# KEYCLOAK - the platform's user store (one per cluster)
#
# Dex stays the issuer every service trusts; Keycloak is Dex's one connector
# and the place users, tenants and groups live, with delegated admins
# (modules/keycloak-realm). Its state is global -- a database of its own that
# no preview branches -- because who exists must not differ per environment.
#
# The chart runs `kc.sh start` against the caller's Postgres. Hostname v2:
# KC_HOSTNAME is the one base URL in tokens; back-channel calls may arrive
# under another name (the realm module's provider through a NodePort) when
# backchannel_dynamic is set. The bootstrap admin is a service-account client
# with a generated secret, not a user: tofu configures the realm with it, and
# no master-realm password exists to guess. The public Ingress publishes only
# the platform realms and /resources; master and the admin console live on
# admin_hostname.
# ------------------------------------------------------------------------------

locals {
  namespace    = var.create_namespace ? kubernetes_namespace_v1.keycloak[0].metadata[0].name : var.namespace
  service_name = "${var.release_name}-http"
  internal_url = "http://${local.service_name}.${local.namespace}.svc.cluster.local"

  db_secret    = "${var.release_name}-db"
  admin_secret = "${var.release_name}-bootstrap-admin"

  ingress_paths = var.ingress.paths != null ? var.ingress.paths : concat([for r in var.ingress.realms : "/realms/${r}"], ["/resources"])

  # The chart already sets KC_HTTP_ENABLED, KC_HEALTH_ENABLED and the KC_DB_*.
  env = merge(
    {
      KC_HOSTNAME = var.hostname
      # Fine-grained admin permissions v2: delegated tenant and group admins.
      KC_FEATURES = "admin-fine-grained-authz:v2"
    },
    var.backchannel_dynamic ? { KC_HOSTNAME_BACKCHANNEL_DYNAMIC = "true" } : {},
    var.admin_hostname != "" ? { KC_HOSTNAME_ADMIN = var.admin_hostname } : {},
    var.proxy_headers != "" ? { KC_PROXY_HEADERS = var.proxy_headers } : {},
    var.extra_env,
  )

  extra_env = concat(
    [for k, v in local.env : { name = k, value = v }],
    [
      { name = "KC_BOOTSTRAP_ADMIN_CLIENT_ID", valueFrom = { secretKeyRef = { name = local.admin_secret, key = "client-id" } } },
      { name = "KC_BOOTSTRAP_ADMIN_CLIENT_SECRET", valueFrom = { secretKeyRef = { name = local.admin_secret, key = "client-secret" } } },
    ],
  )

  values = yamlencode({
    fullnameOverride = var.release_name
    image            = var.image_tag != "" ? { tag = var.image_tag } : {}
    command          = ["/opt/keycloak/bin/kc.sh", "start"]
    extraEnv         = yamlencode(local.extra_env)
    # Keycloak serves at the root (issuer https://<host>/realms/<realm>), not
    # under the chart's legacy /auth.
    http = { relativePath = "/" }
    # proxy_headers above replaces the chart's own KC_PROXY_HEADERS default.
    proxy = { enabled = false }
    database = {
      vendor            = "postgres"
      hostname          = var.database.host
      port              = var.database.port
      database          = var.database.name
      username          = var.database.username
      existingSecret    = local.db_secret
      existingSecretKey = "password"
    }
    service = merge(
      { type = var.service_type },
      var.node_port != null ? { httpNodePort = var.node_port } : {},
    )
    ingress = merge(
      { enabled = var.ingress.enabled },
      {
        for k, v in {
          ingressClassName = var.ingress.class_name
          annotations      = var.ingress.annotations
          rules            = [{ host = var.ingress.host, paths = [for path in local.ingress_paths : { path = path, pathType = "Prefix" }] }]
          tls = var.ingress.tls_secret_name != "" ? [{
            secretName = var.ingress.tls_secret_name
            hosts      = [var.ingress.host]
          }] : []
        } : k => v if var.ingress.enabled
      },
    )
    resources    = var.resources
    nodeSelector = var.node_selector
    tolerations  = var.tolerations
  })
}

resource "kubernetes_namespace_v1" "keycloak" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace
  }
}

resource "random_password" "bootstrap_admin" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "bootstrap_admin" {
  metadata {
    name      = local.admin_secret
    namespace = local.namespace
  }

  data = {
    client-id     = var.bootstrap_admin_client_id
    client-secret = random_password.bootstrap_admin.result
  }
}

resource "kubernetes_secret_v1" "db" {
  metadata {
    name      = local.db_secret
    namespace = local.namespace
  }

  data = { password = var.database.password }
}

resource "helm_release" "keycloak" {
  name       = var.release_name
  namespace  = local.namespace
  repository = var.chart_repository
  chart      = "keycloakx"
  version    = var.chart_version
  # First start migrates the database and builds; the realm module needs the
  # admin API right after.
  timeout = 900
  wait    = true

  values = concat([local.values], var.extra_values)

  depends_on = [kubernetes_secret_v1.bootstrap_admin, kubernetes_secret_v1.db]
}

resource "kubernetes_ingress_v1" "admin" {
  count = var.admin_ingress.enabled ? 1 : 0

  metadata {
    name        = "${var.release_name}-admin"
    namespace   = local.namespace
    annotations = var.admin_ingress.annotations
  }

  spec {
    ingress_class_name = var.admin_ingress.class_name != "" ? var.admin_ingress.class_name : null

    dynamic "tls" {
      for_each = var.admin_ingress.tls_secret_name != "" || var.admin_ingress.class_name == "tailscale" ? [1] : []
      content {
        hosts       = [var.admin_ingress.host]
        secret_name = var.admin_ingress.tls_secret_name != "" ? var.admin_ingress.tls_secret_name : null
      }
    }

    rule {
      host = var.admin_ingress.class_name == "tailscale" ? null : var.admin_ingress.host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = local.service_name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.admin_hostname != ""
      error_message = "admin_ingress serves admin_hostname: set it (the admin console's base URL on that host)."
    }
  }

  depends_on = [helm_release.keycloak]
}
