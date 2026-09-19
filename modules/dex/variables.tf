variable "namespace" {
  description = "Namespace for Dex. Environments register their OAuth2Client CRs here (modules/workloads auth.dex_namespace)."
  type        = string
  default     = "dex"
}

variable "create_namespace" {
  description = "Create the namespace (false to deploy into an existing one)"
  type        = bool
  default     = true
}

variable "release_name" {
  description = "Helm release name; the chart derives the Service name from it"
  type        = string
  default     = "dex"
}

variable "chart_version" {
  description = "dexidp/dex Helm chart version"
  type        = string
  default     = "0.24.1"
}

variable "chart_repository" {
  description = "Helm repository holding the dex chart"
  type        = string
  default     = "https://charts.dexidp.io"
}

variable "image_tag" {
  description = "Dex image tag; empty uses the chart's appVersion"
  type        = string
  default     = ""
}

variable "issuer_url" {
  description = <<-EOT
    The OIDC issuer URL, i.e. the URL browsers AND pods reach Dex at, including
    the path Dex serves under. Every relying party validates tokens against
    this exact string, so it must resolve identically from both. On a kind
    cluster the in-cluster Service URL works for both
    (http://dex.dex.svc.cluster.local:5556/dex); on a real cluster use the
    Ingress hostname (https://dex.example.com/dex).
  EOT
  type        = string

  validation {
    condition     = can(regex("^https?://", var.issuer_url))
    error_message = "issuer_url must be an http(s) URL."
  }
}

variable "connectors" {
  description = <<-EOT
    Dex connectors: the upstream identity providers users actually log in with,
    as the objects Dex's config.yaml takes (type, id, name, config). Any of
    Dex's connectors works -- google, github, microsoft, ldap, saml, oidc
    (generic) -- and swapping one for another changes nothing downstream:
    relying parties only ever see Dex. `mockCallback` (a fixed test identity
    in group "authors") is useful in CI. Sensitive: connector configs carry
    client secrets. Example:

      connectors = [{
        type = "google"
        id   = "google"
        name = "Google"
        config = {
          clientID     = var.google_client_id
          clientSecret = var.google_client_secret
          redirectURI  = "https://dex.example.com/dex/callback"
          hostedDomains = ["example.com"]
        }
      }]
  EOT
  type        = list(any)
  default     = []
  sensitive   = true
}

variable "connector_env" {
  description = <<-EOT
    Secret values for the connectors, as environment variables of the Dex
    pod: reference them as $NAME in `connectors` (Dex expands them), e.g.
    connector_env = { GOOGLE_CLIENT_SECRET = var.google_client_secret } with
    clientSecret = "$GOOGLE_CLIENT_SECRET". They land in a Secret this module
    creates (so still in tofu state, but not in the Helm release or Dex's
    rendered config). Prefer connector_env_secret_name to keep them out of
    state as well.
  EOT
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "connector_env_secret_name" {
  description = "Name of an existing Secret in Dex's namespace (created outside tofu, e.g. by External Secrets) whose keys become Dex's environment for $NAME expansion in `connectors`. Takes precedence over connector_env."
  type        = string
  default     = ""
}

variable "client_admission" {
  description = <<-EOT
    A ValidatingAdmissionPolicy on OAuth2Client objects in Dex's namespace:
    requests from restricted principals (Kubernetes usernames starting with
    one of restricted_user_prefixes, or members of restricted_groups -- e.g.
    the preview CI role's username) may only create, change or delete
    clients whose id matches allowed_id_pattern (a preview's own "pr<N>-"
    prefix), so a PR's tofu cannot rewrite prod's redirect URIs. Everyone
    else is unaffected. Null disables it. Needs Kubernetes >= 1.30.
  EOT
  type = object({
    restricted_user_prefixes = optional(list(string), [])
    restricted_groups        = optional(list(string), [])
    allowed_id_pattern       = optional(string, "^pr[0-9]+-")
  })
  default = null

  validation {
    condition     = var.client_admission == null || length(try(var.client_admission.restricted_user_prefixes, [])) + length(try(var.client_admission.restricted_groups, [])) > 0
    error_message = "client_admission needs at least one restricted user prefix or group."
  }
}

variable "enable_password_db" {
  description = "Enable Dex's built-in local users (static_passwords). For CI and laptops; production logs in through a connector."
  type        = bool
  default     = false
}

variable "static_passwords" {
  description = <<-EOT
    Local users for enable_password_db: email, bcrypt hash of the password,
    display username, and a stable user_id. Local users have no groups. Dex's
    documented example hash `$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W`
    is the word "password".
  EOT
  type = list(object({
    email    = string
    hash     = string
    username = string
    user_id  = string
  }))
  default   = []
  sensitive = true
}

variable "static_clients" {
  description = <<-EOT
    OAuth2 clients fixed in Dex's config (bring-your-own). Environments
    stamped by modules/workloads register theirs dynamically as OAuth2Client
    CRs instead, so this is for clients outside the platform (kubectl OIDC
    login, a CLI). `public = true` clients need no secret (native apps).
  EOT
  type = list(object({
    id            = string
    name          = string
    secret        = optional(string, "")
    redirect_uris = optional(list(string), [])
    public        = optional(bool, false)
  }))
  default   = []
  sensitive = true
}

variable "skip_approval_screen" {
  description = "Skip Dex's consent page after upstream login (single-org platforms want this)"
  type        = bool
  default     = true
}

variable "id_token_expiry" {
  description = "Lifetime of the ID tokens Dex issues (Go duration). Short, because relying parties (oauth2-proxy, the webapp) re-validate by refreshing: a user removed from a group loses what the group granted within this window."
  type        = string
  default     = "1h"
}

variable "ingress" {
  description = <<-EOT
    Expose Dex through an Ingress. Required whenever the issuer_url is not an
    in-cluster address: the login page must be reachable by browsers, and the
    token endpoint by the pods (oauth2-proxy, Argo, JupyterHub, the webapp).
    `annotations` are passed through (cert-manager, external-dns, ALB, ...);
    `tls_secret_name` is the pre-existing TLS Secret for the host, empty for a
    controller that terminates TLS itself.
  EOT
  type = object({
    enabled         = optional(bool, false)
    class_name      = optional(string, "")
    host            = optional(string, "")
    path            = optional(string, "/dex")
    annotations     = optional(map(string), {})
    tls_secret_name = optional(string, "")
  })
  default = {}

  validation {
    condition     = !var.ingress.enabled || var.ingress.host != ""
    error_message = "ingress.host is required when ingress.enabled = true."
  }
}

variable "node_selector" {
  description = "nodeSelector for the Dex pod"
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the Dex pod"
  type        = list(any)
  default     = []
}

variable "resources" {
  description = "Container resources for the Dex pod"
  type        = any
  default = {
    requests = { cpu = "50m", memory = "64Mi" }
    limits   = { memory = "256Mi" }
  }
}

variable "extra_values" {
  description = "Additional Helm values documents (YAML strings) merged after the module's; later documents win"
  type        = list(string)
  default     = []
}
