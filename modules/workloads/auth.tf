# ------------------------------------------------------------------------------
# WORKLOADS MODULE - AUTH (var.auth; see the variable for the three modes)
#
# mode "oidc" turns the environment into a set of OIDC relying parties against
# one issuer (modules/dex, or any other):
#
#   oauth2-proxy per protected service   Dagster, MLflow, the Ray dashboard and
#                                        optionally the webapp have no login of
#                                        their own. Each gets a reverse proxy
#                                        that runs the login, enforces the
#                                        service's gate (protect[svc]) and hands
#                                        the upstream X-Forwarded-Email/-Groups.
#                                        The private Ingress points at the proxy
#                                        (ingress.tf), so this works behind any
#                                        IngressClass, Tailscale included.
#   Argo Workflows                       native SSO + group rbac-rules (argo.tf
#                                        consumes local.argo_sso_*).
#   JupyterHub                           the oidc mechanism against the issuer
#                                        (jupyterhub.tf consumes
#                                        local.jupyterhub_oidc).
#   the webapp                           OIDC_* env to run its own login, so its
#                                        users, sessions and memberships live in
#                                        its own database and branch with it.
#
# Clients: with auth.dex_namespace set, each is an OAuth2Client custom resource
# in Dex's namespace with a generated secret -- Dex's kubernetes storage looks
# a client up by an object name derived from its id (base32 of the id plus an
# FNV suffix), computed below in HCL so no external tool is needed. Without
# it, the caller brings clients registered by hand (auth.clients).
#
# What is state here and what is not: identity (who exists, which groups) is
# the upstream IdP's and global; the clients, proxy cookies and rbac SAs here
# are stamped per environment and destroyed with it; users/sessions/roles the
# webapp writes are in its database and fork with the preview. docs/auth.md.
# ------------------------------------------------------------------------------

locals {
  auth_oidc = var.auth.mode == "oidc"
  auth_dex  = local.auth_oidc && var.auth.dex_namespace != ""

  # --- Which services get a proxy ---------------------------------------------
  auth_service_enabled = {
    dagster = local.enable_dagster
    mlflow  = var.enable_mlflow
    ray     = var.enable_ray
    webapp  = var.enable_webapp
  }
  # superadmin_group closes what the caller left open: an ungated Ray
  # dashboard becomes superadmins-only. MLflow on its own OIDC leaves the proxy.
  mlflow_oidc = local.auth_oidc && var.enable_mlflow && var.auth.mlflow_mode == "oidc"
  auth_protect = {
    for svc, gate in var.auth.protect : svc => (
      svc == "ray" && var.auth.superadmin_group != "" && length(gate.allowed_groups) == 0 && length(gate.allowed_emails) == 0
      ? merge(gate, { allowed_groups = [var.auth.superadmin_group] })
      : gate
    ) if !(svc == "mlflow" && var.auth.mlflow_mode == "oidc")
  }
  proxied_services = {
    for svc, gate in local.auth_protect : svc => gate
    if local.auth_oidc && lookup(local.auth_service_enabled, svc, false)
  }
  webapp_proxied = contains(keys(local.proxied_services), "webapp")

  # The Service each proxy fronts (namespace, name, port) and its own name.
  proxy_upstream = {
    dagster = { namespace = local.dagster_namespace, service = local.dagster_webserver_service, port = 80, role = "dagster" }
    mlflow  = { namespace = local.mlflow_namespace, service = local.mlflow_service, port = 80, role = "mlflow" }
    ray     = { namespace = local.ray_namespace, service = local.ray_dashboard_service, port = 80, role = "ray_head" }
    webapp  = { namespace = local.webapp_namespace, service = var.webapp_app_name, port = 80, role = "webapp" }
  }
  proxy_service_name = { for svc in keys(local.proxy_upstream) : svc => "${svc}-auth" }

  # --- Browser-facing URLs (redirect URIs are derived from these) --------------
  auth_private_urls_known = var.enable_private_ingress && var.private_ingress_dns_suffix != ""
  auth_private_host = {
    dagster = local.private_dagster_host
    mlflow  = local.private_mlflow_host
    ray     = local.private_ray_host
    webapp  = local.private_webapp_host
    argo    = local.private_argo_host
  }
  # With a private Ingress the proxy is reached at the service's private
  # hostname; without one (kind, port-forwards) at its in-cluster Service URL,
  # which is also what the smoke test's in-cluster curl uses.
  auth_external_url = merge(
    {
      for svc, up in local.proxy_upstream :
      svc => local.auth_private_urls_known ? "${var.auth.external_scheme}://${local.auth_private_host[svc]}.${var.private_ingress_dns_suffix}" : "http://${local.proxy_service_name[svc]}.${up.namespace}.svc.cluster.local"
    },
    {
      argo = local.auth_private_urls_known ? "${var.auth.external_scheme}://${local.private_argo_host}.${var.private_ingress_dns_suffix}" : "http://${local.argo_server_service}.${local.argo_namespace}.svc.cluster.local:2746"
      # JupyterHub is public-Ingress-only in this module; in-cluster otherwise.
      jupyterhub = var.jupyterhub_public_host != "" ? "https://${var.jupyterhub_public_host}" : "http://proxy-public.${local.jupyterhub_namespace}.svc.cluster.local"
    },
  )
  # MLflow on its own OIDC is reached at its own Service (or private host).
  mlflow_login_url = local.auth_private_urls_known ? "${var.auth.external_scheme}://${local.private_mlflow_host}.${var.private_ingress_dns_suffix}" : "http://${local.mlflow_service}.${local.mlflow_namespace}.svc.cluster.local"
  # An unproxied webapp runs its own login at its own URL.
  webapp_login_url = local.auth_private_urls_known ? "${var.auth.external_scheme}://${local.private_webapp_host}.${var.private_ingress_dns_suffix}" : "http://${var.webapp_app_name}.${local.webapp_namespace}.svc.cluster.local"

  # --- The environment's OAuth2 clients ----------------------------------------
  jupyterhub_oidc_from_dex = local.auth_dex && var.enable_jupyterhub && local.jupyterhub_mechanism == "oidc" && var.jupyterhub_oidc_client_id == ""

  auth_clients_needed = {
    for k, needed in {
      "oauth2-proxy" = length(local.proxied_services) > 0
      argo           = var.enable_argo_workflows
      jupyterhub     = local.jupyterhub_oidc_from_dex
      webapp         = var.enable_webapp && !local.webapp_proxied
      mlflow         = local.mlflow_oidc
    } : k => needed if local.auth_oidc && needed
  }

  auth_client_id = { for k in keys(local.auth_clients_needed) : k => "${local.prefix}${k}" }

  auth_redirect_uris = {
    "oauth2-proxy" = [for svc in sort(keys(local.proxied_services)) : "${local.auth_external_url[svc]}/oauth2/callback"]
    argo           = ["${local.auth_external_url.argo}/oauth2/callback"]
    jupyterhub     = ["${local.auth_external_url.jupyterhub}/hub/oauth_callback"]
    webapp         = ["${local.webapp_login_url}/auth/callback"]
    mlflow         = ["${local.mlflow_login_url}/callback"]
  }

  # Resolved id + secret per client: generated (Dex) or brought (auth.clients).
  auth_client = {
    for k in keys(local.auth_clients_needed) : k => {
      id     = local.auth_dex ? local.auth_client_id[k] : try(var.auth.clients[k].client_id, "")
      secret = local.auth_dex ? try(random_password.auth_client[k].result, "") : try(var.auth.clients[k].client_secret, "")
    }
  }
  auth_clients_missing = [for k in keys(local.auth_clients_needed) : k if !local.auth_dex && !contains(keys(var.auth.clients), k)]

  # --- Dex's object name for a client id ---------------------------------------
  # Dex's kubernetes storage names an OAuth2Client
  #   base32(id bytes ++ fnv.New64().Sum(nil)), lowercase alphabet, no padding
  # (storage/kubernetes/client.go idToName: `h().Sum([]byte(s))` appends the
  # hash of nothing -- the FNV-1 64 offset basis, 0xcbf29ce484222325 -- to the
  # id). Reproduced here in HCL so the CR can be created without any tool.
  b32_alphabet    = split("", "abcdefghijklmnopqrstuvwxyz234567")
  dex_name_suffix = [203, 242, 156, 228, 132, 34, 35, 37]
  ascii = merge(
    { for i, c in split("", "abcdefghijklmnopqrstuvwxyz") : c => 97 + i },
    { for i, c in split("", "0123456789") : c => 48 + i },
    { "-" = 45, "." = 46, "_" = 95 },
  )
  dex_client_object_name = {
    for k, id in local.auth_client_id : k => join("", [
      for chunk in chunklist(flatten([
        for byte in concat([for ch in split("", id) : local.ascii[ch]], local.dex_name_suffix) :
        [for i in range(8) : floor(byte / pow(2, 7 - i)) % 2]
      ]), 5) :
      local.b32_alphabet[sum([
        for i, bit in concat(chunk, slice([0, 0, 0, 0], 0, 5 - length(chunk))) : bit * pow(2, 4 - i)
      ])]
    ])
  }

  # --- What the other files consume -----------------------------------------
  argo_sso        = local.auth_oidc && var.enable_argo_workflows
  argo_sso_secret = "argo-sso-client"
  # Group -> ServiceAccount rules for Argo's SSO RBAC, exactly as given: no
  # implicit catch-all (a user matching no rule gets no Argo). Argo evaluates
  # the numerically HIGHEST precedence first, so broad rules want low values.
  argo_rbac_rules = local.argo_sso ? merge(
    var.auth.superadmin_group != "" ? {
      platform-admins = { rule = "'${var.auth.superadmin_group}' in groups", access = "write", precedence = 100 }
    } : {},
    var.auth.argo_rbac_rules,
  ) : {}
  argo_access_levels = {
    read  = ["get", "list", "watch"]
    write = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  argo_levels_used = toset([for r in values(local.argo_rbac_rules) : r.access])

  jupyterhub_oidc = local.jupyterhub_oidc_from_dex ? {
    client_id     = local.auth_client.jupyterhub.id
    client_secret = local.auth_client.jupyterhub.secret
    callback_url  = local.auth_redirect_uris.jupyterhub[0]
    authorize_url = "${var.auth.issuer_url}/auth"
    token_url     = "${var.auth.issuer_url}/token"
    userdata_url  = "${var.auth.issuer_url}/userinfo"
    # offline_access: Dex issues a refresh token, which refresh_pre_spawn uses.
    scopes        = distinct(concat(var.auth.scopes, ["offline_access"]))
    login_service = "Dex"
    } : {
    client_id     = var.jupyterhub_oidc_client_id
    client_secret = var.jupyterhub_oidc_client_secret
    callback_url  = var.jupyterhub_oidc_callback_url
    authorize_url = var.jupyterhub_oidc_authorize_url
    token_url     = var.jupyterhub_oidc_token_url
    userdata_url  = var.jupyterhub_oidc_userdata_url
    scopes        = var.jupyterhub_oidc_scopes
    login_service = var.jupyterhub_oidc_login_service
  }

  # The webapp's identity contract (webapp.tf merges these into its env and
  # secret): AUTH_MODE names the one source the app accepts. Behind its
  # oauth2-proxy the webapp verifies the ID token the proxy forwards
  # (IDENTITY_JWT_*) instead of trusting X-Forwarded-* headers.
  webapp_auth_env = merge(
    {
      AUTH_MODE     = var.auth.mode
      COOKIE_SECURE = tostring(var.auth.cookie_secure)
    },
    var.auth.mode == "headers" ? merge(
      { IDENTITY_HEADER = var.auth.identity_header },
      var.auth.identity_groups_header != "" ? { IDENTITY_GROUPS_HEADER = var.auth.identity_groups_header } : {},
    ) : {},
    local.webapp_proxied ? {
      AUTH_PROXIED          = "1"
      IDENTITY_JWT_ISSUER   = var.auth.issuer_url
      IDENTITY_JWT_AUDIENCE = local.auth_client["oauth2-proxy"].id
      OIDC_GROUPS_CLAIM     = var.auth.groups_claim
    } : {},
    var.auth.superadmin_group != "" ? { APP_ADMIN_GROUP = var.auth.superadmin_group } : {},
    contains(keys(local.auth_clients_needed), "webapp") ? {
      OIDC_ISSUER_URL   = var.auth.issuer_url
      OIDC_CLIENT_ID    = local.auth_client.webapp.id
      OIDC_REDIRECT_URL = local.auth_redirect_uris.webapp[0]
      OIDC_GROUPS_CLAIM = var.auth.groups_claim
      OIDC_SCOPES       = join(" ", var.auth.scopes)
    } : {},
  )
  webapp_auth_secret_env = contains(keys(local.auth_clients_needed), "webapp") ? {
    OIDC_CLIENT_SECRET = local.auth_client.webapp.secret
    SESSION_SECRET     = one(random_password.webapp_session[*].result)
  } : {}
}

# ------------------------------------------------------------------------------
# Secrets: one per client (Dex mode), one cookie secret per environment, one
# session secret for the webapp's own login.
# ------------------------------------------------------------------------------

resource "random_password" "auth_client" {
  for_each = local.auth_dex ? local.auth_clients_needed : {}

  length  = 40
  special = false
}

resource "random_password" "auth_cookie_secret" {
  count = length(local.proxied_services) > 0 ? 1 : 0

  # oauth2-proxy wants 16, 24 or 32 bytes; every character here is one byte.
  length  = 32
  special = false
}

resource "random_password" "webapp_session" {
  count = contains(keys(local.auth_clients_needed), "webapp") ? 1 : 0

  length  = 48
  special = false
}

# ------------------------------------------------------------------------------
# Dex: the environment's clients as OAuth2Client custom resources
# ------------------------------------------------------------------------------

resource "kubectl_manifest" "dex_client" {
  for_each = local.auth_dex ? local.auth_clients_needed : {}

  yaml_body = yamlencode({
    apiVersion = "dex.coreos.com/v1"
    kind       = "OAuth2Client"
    metadata = {
      name      = local.dex_client_object_name[each.key]
      namespace = var.auth.dex_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "lab-platform-workloads"
        "lab-platform/environment"     = var.environment
      }
    }
    id           = local.auth_client_id[each.key]
    secret       = random_password.auth_client[each.key].result
    name         = "${local.auth_client_id[each.key]} (${var.environment})"
    redirectURIs = local.auth_redirect_uris[each.key]
  })

  sensitive_fields = ["secret"]
}

# ------------------------------------------------------------------------------
# oauth2-proxy per protected service
# ------------------------------------------------------------------------------

locals {
  # Refreshing the session (and so re-reading groups) needs a refresh token;
  # Dex issues one for offline_access. Brought issuers may name it otherwise.
  oauth2_proxy_scopes = local.auth_dex ? distinct(concat(var.auth.scopes, ["offline_access"])) : var.auth.scopes

  # Who a gate admits. Default-deny: a proxied service must name groups,
  # emails, or email domains (allowed_email_domains = ["*"] is an explicit
  # choice to admit everyone the issuer admits). oauth2-proxy authenticates by
  # domain or emails file, then authorizes by group, so a group-only gate
  # authenticates any domain and lets --allowed-group decide.
  auth_gate_open = {
    for svc, gate in local.proxied_services :
    svc => length(gate.allowed_groups) == 0 && length(gate.allowed_emails) == 0 && length(var.auth.allowed_email_domains) == 0
  }
  auth_gate_domains = {
    for svc, gate in local.proxied_services :
    svc => length(var.auth.allowed_email_domains) > 0 ? var.auth.allowed_email_domains : (
      length(gate.allowed_emails) == 0 ? ["*"] : []
    )
  }

  oauth2_proxy_args = {
    for svc, gate in local.proxied_services : svc => concat(
      [
        "--provider=oidc",
        "--oidc-issuer-url=${var.auth.issuer_url}",
        "--client-id=${local.auth_client["oauth2-proxy"].id}",
        # Secrets arrive as files from the <svc>-auth Secret, not env.
        "--client-secret-file=/etc/oauth2-proxy/credentials/client-secret",
        "--cookie-secret-file=/etc/oauth2-proxy/credentials/cookie-secret",
        "--scope=${join(" ", local.oauth2_proxy_scopes)}",
        "--http-address=0.0.0.0:4180",
        "--upstream=http://${local.proxy_upstream[svc].service}.${local.proxy_upstream[svc].namespace}.svc.cluster.local:${local.proxy_upstream[svc].port}",
        "--redirect-url=${local.auth_external_url[svc]}/oauth2/callback",
        # oauth2-proxy's default is approval_prompt=force, which makes Dex show
        # its consent page even with skipApprovalScreen; "auto" lets the
        # issuer decide.
        "--approval-prompt=auto",
        # Host-only cookies: on a flat tailnet one environment's hosts sit
        # beside every other's (pr7-dagster.<suffix> next to dagster.<suffix>),
        # so any shared cookie domain would carry prod's session to previews.
        "--cookie-name=_${local.prefix}lab_auth",
        "--cookie-secure=${var.auth.cookie_secure}",
        "--cookie-samesite=lax",
        # Re-validate (and re-read groups) every session_refresh, end the
        # session after session_lifetime: a revoked group stops working within
        # the refresh interval, not oauth2-proxy's week-long default.
        "--cookie-refresh=${var.auth.session_refresh}",
        "--cookie-expire=${var.auth.session_lifetime}",
        "--set-xauthrequest=true",
        "--pass-user-headers=true",
        "--pass-access-token=false",
        "--skip-provider-button=true",
        "--reverse-proxy=${local.auth_private_urls_known}",
      ],
      # The webapp verifies the proxy's ID token itself (IDENTITY_JWT_*).
      svc == "webapp" ? ["--pass-authorization-header=true"] : [],
      [for d in local.auth_gate_domains[svc] : "--email-domain=${d}"],
      length(gate.allowed_groups) > 0 ? ["--oidc-groups-claim=${var.auth.groups_claim}"] : [],
      [for g in gate.allowed_groups : "--allowed-group=${g}"],
      length(gate.allowed_emails) > 0 ? ["--authenticated-emails-file=/etc/oauth2-proxy/emails.txt"] : [],
      [for r in gate.skip_auth_routes : "--skip-auth-route=${r}"],
    )
  }
  oauth2_proxy_labels = { for svc in keys(local.proxied_services) : svc => { app = local.proxy_service_name[svc] } }
}

resource "kubernetes_secret_v1" "oauth2_proxy" {
  for_each = local.proxied_services

  metadata {
    name      = local.proxy_service_name[each.key]
    namespace = local.proxy_upstream[each.key].namespace
  }

  data = {
    client-secret = local.auth_client["oauth2-proxy"].secret
    cookie-secret = random_password.auth_cookie_secret[0].result
  }

  lifecycle {
    precondition {
      condition     = length(local.auth_clients_missing) == 0
      error_message = "auth.mode = \"oidc\" without auth.dex_namespace needs auth.clients for: ${join(", ", local.auth_clients_missing)}."
    }
    precondition {
      condition     = !local.auth_gate_open[each.key]
      error_message = "auth.protect.${each.key} admits nobody in particular: name allowed_groups or allowed_emails for it, or set auth.allowed_email_domains (use [\"*\"] only if the issuer's connectors already restrict who can log in)."
    }
  }

  depends_on = [
    kubernetes_namespace_v1.dagster,
    kubernetes_namespace_v1.mlflow,
    kubernetes_namespace_v1.ray,
    kubernetes_namespace_v1.webapp,
    kubernetes_role_binding_v1.namespace_admin,
  ]
}

resource "kubernetes_config_map_v1" "oauth2_proxy_emails" {
  for_each = { for svc, gate in local.proxied_services : svc => gate if length(gate.allowed_emails) > 0 }

  metadata {
    name      = "${local.proxy_service_name[each.key]}-emails"
    namespace = local.proxy_upstream[each.key].namespace
  }

  data = { "emails.txt" = join("\n", each.value.allowed_emails) }

  depends_on = [kubernetes_secret_v1.oauth2_proxy]
}

resource "kubernetes_deployment_v1" "oauth2_proxy" {
  #checkov:skip=CKV_K8S_43:the image is pinned by tag (oauth2_proxy_image) and bumped like every other pin in this repo; a digest would defeat that
  for_each = local.proxied_services

  metadata {
    name      = local.proxy_service_name[each.key]
    namespace = local.proxy_upstream[each.key].namespace
    labels    = local.oauth2_proxy_labels[each.key]
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.oauth2_proxy_labels[each.key]
    }

    template {
      metadata {
        labels = local.oauth2_proxy_labels[each.key]
      }

      spec {
        node_selector = local.scheduling[local.proxy_upstream[each.key].role].node_selector

        # The image runs as its own non-root user (65532); nothing here needs
        # more than a read-only filesystem and no capabilities.
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532
          fs_group        = 65532
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        dynamic "toleration" {
          for_each = local.scheduling[local.proxy_upstream[each.key].role].tolerations
          content {
            key      = lookup(toleration.value, "key", null)
            operator = lookup(toleration.value, "operator", null)
            value    = lookup(toleration.value, "value", null)
            effect   = lookup(toleration.value, "effect", null)
          }
        }

        volume {
          name = "credentials"
          secret {
            secret_name = kubernetes_secret_v1.oauth2_proxy[each.key].metadata[0].name
          }
        }

        dynamic "volume" {
          for_each = length(each.value.allowed_emails) > 0 ? [1] : []
          content {
            name = "emails"
            config_map {
              name = kubernetes_config_map_v1.oauth2_proxy_emails[each.key].metadata[0].name
            }
          }
        }

        container {
          name              = "oauth2-proxy"
          image             = var.oauth2_proxy_image
          image_pull_policy = "Always"
          args              = local.oauth2_proxy_args[each.key]

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities {
              drop = ["ALL"]
            }
          }

          port {
            name           = "http"
            container_port = 4180
          }

          volume_mount {
            name       = "credentials"
            mount_path = "/etc/oauth2-proxy/credentials"
            read_only  = true
          }

          dynamic "volume_mount" {
            for_each = length(each.value.allowed_emails) > 0 ? [1] : []
            content {
              name       = "emails"
              mount_path = "/etc/oauth2-proxy/emails.txt"
              sub_path   = "emails.txt"
              read_only  = true
            }
          }

          readiness_probe {
            http_get {
              path = "/ping"
              port = 4180
            }
            period_seconds = 5
          }

          liveness_probe {
            http_get {
              path = "/ping"
              port = 4180
            }
            initial_delay_seconds = 10
            period_seconds        = 20
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "oauth2_proxy" {
  for_each = local.proxied_services

  metadata {
    name      = local.proxy_service_name[each.key]
    namespace = local.proxy_upstream[each.key].namespace
  }

  spec {
    selector = local.oauth2_proxy_labels[each.key]

    port {
      name        = "http"
      port        = 80
      target_port = 4180
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment_v1.oauth2_proxy]
}

# ------------------------------------------------------------------------------
# Argo Workflows SSO: the client Secret the chart reads, and one ServiceAccount
# per rbac rule (what an authenticated user may do, by group)
# ------------------------------------------------------------------------------

resource "kubernetes_secret_v1" "argo_sso" {
  count = local.argo_sso ? 1 : 0

  metadata {
    name      = local.argo_sso_secret
    namespace = local.argo_namespace
  }

  data = {
    client-id     = local.auth_client.argo.id
    client-secret = local.auth_client.argo.secret
  }

  lifecycle {
    precondition {
      condition     = length(local.auth_clients_missing) == 0
      error_message = "auth.mode = \"oidc\" without auth.dex_namespace needs auth.clients for: ${join(", ", local.auth_clients_missing)}."
    }
    precondition {
      condition     = length(local.argo_rbac_rules) > 0
      error_message = "Argo's SSO admits only users matching auth.argo_rbac_rules, and none are set, so nobody could use Argo. Add at least one, e.g. { admins = { rule = \"'platform' in groups\", access = \"write\", precedence = 10 } }."
    }
  }
}

resource "kubernetes_service_account_v1" "argo_sso" {
  for_each = local.argo_rbac_rules

  metadata {
    name      = "argo-ui-${each.key}"
    namespace = local.argo_namespace
    annotations = {
      "workflows.argoproj.io/rbac-rule"            = each.value.rule
      "workflows.argoproj.io/rbac-rule-precedence" = tostring(each.value.precedence)
    }
  }
}

# Argo's server acts as the matched ServiceAccount, which (Kubernetes >= 1.24)
# needs a long-lived token Secret.
resource "kubernetes_secret_v1" "argo_sso_token" {
  for_each = local.argo_rbac_rules

  metadata {
    name      = "argo-ui-${each.key}.service-account-token"
    namespace = local.argo_namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.argo_sso[each.key].metadata[0].name
    }
  }

  type = "kubernetes.io/service-account-token"

  wait_for_service_account_token = false
}

# One Role per access level: `read` sees workflows, templates and logs;
# `write` also submits, resubmits, edits and deletes.
resource "kubernetes_role_v1" "argo_sso" {
  for_each = local.argo_levels_used

  metadata {
    name      = "argo-ui-${each.key}"
    namespace = local.argo_namespace
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflows", "workflowtemplates", "cronworkflows", "workfloweventbindings", "workflowtaskresults"]
    verbs      = local.argo_access_levels[each.key]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "events"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "argo_sso" {
  for_each = local.argo_levels_used

  metadata {
    name      = "argo-ui-${each.key}"
    namespace = local.argo_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.argo_sso[each.key].metadata[0].name
  }

  dynamic "subject" {
    for_each = { for name, r in local.argo_rbac_rules : name => r if r.access == each.key }
    content {
      kind      = "ServiceAccount"
      name      = kubernetes_service_account_v1.argo_sso[subject.key].metadata[0].name
      namespace = local.argo_namespace
    }
  }
}
