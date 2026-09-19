# ------------------------------------------------------------------------------
# DEX - the platform's OIDC issuer (one per cluster)
#
# Dex owns no users: it brokers whatever identity provider the connectors name
# (Google, GitHub, LDAP, SAML, another OIDC issuer) -- or, for CI and laptops,
# its local password DB -- and re-issues standard OIDC tokens. Every relying
# party on the cluster (oauth2-proxy in front of Dagster/MLflow/Ray, Argo's
# native SSO, JupyterHub, the webapp) trusts this one issuer, so the upstream
# IdP is swappable in one place and per-environment stamps can mint their own
# OAuth2 clients: with the `kubernetes` storage backend, a client is an
# OAuth2Client custom resource in this namespace, which modules/workloads
# creates and deletes with the environment.
# ------------------------------------------------------------------------------

locals {
  namespace = var.create_namespace ? kubernetes_namespace_v1.dex[0].metadata[0].name : var.namespace

  # fullnameOverride pins the Service name to the release name (the chart
  # would otherwise append "-dex" when the release name does not contain it).
  service_name   = var.release_name
  in_cluster_url = "http://${local.service_name}.${local.namespace}.svc.cluster.local:5556"

  static_passwords = [
    for p in var.static_passwords : {
      email    = p.email
      hash     = p.hash
      username = p.username
      userID   = p.user_id
    }
  ]

  # Filtered for-expressions keep `public` a bool: a conditional between
  # {public = true} and {secret = "..."} would unify both to strings.
  static_clients = [
    for c in var.static_clients : merge(
      { id = c.id, name = c.name, redirectURIs = c.redirect_uris },
      { for k, v in { public = true } : k => v if c.public },
      { for k, v in { secret = c.secret } : k => v if !c.public },
    )
  ]

  # Dex's config.yaml (the chart renders `config` into its Secret).
  dex_config = merge(
    {
      issuer = var.issuer_url
      storage = {
        type   = "kubernetes"
        config = { inCluster = true }
      }
      web = { http = "0.0.0.0:5556" }
      oauth2 = {
        skipApprovalScreen = var.skip_approval_screen
        responseTypes      = ["code"]
      }
      expiry           = { idTokens = var.id_token_expiry }
      enablePasswordDB = var.enable_password_db
      connectors       = var.connectors
    },
    length(local.static_passwords) > 0 ? { staticPasswords = local.static_passwords } : {},
    length(local.static_clients) > 0 ? { staticClients = local.static_clients } : {},
  )

  # A filtered for-expression rather than a conditional: the two branches of a
  # conditional must share a type, and `{ enabled = false }` does not.
  ingress_values = merge(
    { enabled = var.ingress.enabled },
    {
      for k, v in {
        className   = var.ingress.class_name
        annotations = var.ingress.annotations
        hosts = [{
          host  = var.ingress.host
          paths = [{ path = var.ingress.path, pathType = "Prefix" }]
        }]
        tls = var.ingress.tls_secret_name != "" ? [{
          secretName = var.ingress.tls_secret_name
          hosts      = [var.ingress.host]
        }] : []
      } : k => v if var.ingress.enabled
    },
  )

  # Connector secrets stay out of the Helm values (and so the release's
  # history) and out of Dex's config Secret: Dex expands $VAR in connector
  # config from its environment, and the environment comes from a Secret --
  # this module's (connector_env) or one created outside tofu entirely
  # (connector_env_secret_name, e.g. by External Secrets).
  connector_env_secret = var.connector_env_secret_name != "" ? var.connector_env_secret_name : (
    length(var.connector_env) > 0 ? "${var.release_name}-connector-env" : ""
  )

  values = yamlencode({
    fullnameOverride = var.release_name
    image            = var.image_tag != "" ? { tag = var.image_tag } : {}
    config           = local.dex_config
    envFrom          = local.connector_env_secret != "" ? [{ secretRef = { name = local.connector_env_secret } }] : []
    service = {
      type  = "ClusterIP"
      ports = { http = { port = 5556 } }
    }
    ingress      = local.ingress_values
    nodeSelector = var.node_selector
    tolerations  = var.tolerations
    resources    = var.resources
  })
}

resource "kubernetes_namespace_v1" "dex" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace
  }
}

resource "kubernetes_secret_v1" "connector_env" {
  count = var.connector_env_secret_name == "" && length(var.connector_env) > 0 ? 1 : 0

  metadata {
    name      = local.connector_env_secret
    namespace = local.namespace
  }

  data = var.connector_env
}

resource "helm_release" "dex" {
  name       = var.release_name
  namespace  = local.namespace
  repository = var.chart_repository
  chart      = "dex"
  version    = var.chart_version
  timeout    = 600
  # The pod must be Ready before consumers create OAuth2Client CRs: Dex
  # registers the dex.coreos.com CRDs itself on first start.
  wait = true

  values = concat([local.values], var.extra_values)

  depends_on = [kubernetes_secret_v1.connector_env]

  lifecycle {
    precondition {
      condition     = var.enable_password_db || length(var.connectors) > 0
      error_message = "Dex needs at least one way to log in: a connector, or enable_password_db with static_passwords."
    }
  }
}
