variable "realm" {
  description = "Realm name; the issuer Dex brokers is <keycloak_base_url>/realms/<realm>"
  type        = string
  default     = "lab"
}

variable "display_name" {
  description = "Realm display name on the login page"
  type        = string
  default     = "Lab"
}

variable "keycloak_base_url" {
  description = "Keycloak's public base URL (modules/keycloak base_url), used to build the issuer URL"
  type        = string
}

variable "ssl_required" {
  description = "\"external\" (HTTPS except from private addresses), \"all\", or \"none\" (kind over plain http)"
  type        = string
  default     = "external"

  validation {
    condition     = contains(["external", "all", "none"], var.ssl_required)
    error_message = "ssl_required must be external, all, or none."
  }
}

variable "tenants" {
  description = <<-EOT
    The platform's tenants (the same map modules/tenancy takes; only the
    group names are read here). Each tenant is a top-level group /<tenant>
    with an /<tenant>/admins group; each of its groups is /<tenant>/<group>
    with /<tenant>/<group>/admins. Tokens carry these full paths. Slugs are
    ^[a-z]([a-z0-9_]{0,19}[a-z0-9])?$ without "__" (they become Postgres role
    names nb_<tenant>__<group>); "admins" is reserved.
  EOT
  # object({}) accepts any object and ignores its attributes: this module
  # reads only the names, whatever else modules/tenancy attaches to a group.
  type = map(object({
    groups = optional(map(object({})), {})
  }))
  default = {}

  validation {
    condition = alltrue(flatten([
      for t, v in var.tenants : concat(
        [can(regex("^[a-z]([a-z0-9_]{0,19}[a-z0-9])?$", t)) && t != "admins" && t != "platform-admins"],
        [for g in keys(v.groups) : can(regex("^[a-z]([a-z0-9_]{0,19}[a-z0-9])?$", g)) && g != "admins"],
      )
    ]))
    error_message = "Tenant and group slugs must match ^[a-z]([a-z0-9_]{0,19}[a-z0-9])?$ (no trailing underscore: nb_<tenant>__<group> must read back unambiguously), and \"admins\" is reserved."
  }
  validation {
    condition     = alltrue([for t in keys(var.tenants) : !strcontains(t, "__")]) && alltrue(flatten([for t, v in var.tenants : [for g in keys(v.groups) : !strcontains(g, "__")]]))
    error_message = "Slugs may not contain \"__\": it separates tenant and group in nb_<tenant>__<group>."
  }
}

variable "superadmins" {
  description = "Emails of the platform's superadmins: members of /platform-admins (realm-admin), authoritative here. Each is pre-created so a brokered login with that verified email links to it."
  type        = list(string)
  default     = []
}

variable "admins_can_view_all_users" {
  description = "Let tenant and group admins look up any user in the realm (needed to add someone who is not yet a member; FGAP v2 user permissions are realm-wide). Memberships stay fenced to their own groups either way."
  type        = bool
  default     = true
}

variable "dex_client_id" {
  description = "Client id of the confidential client Dex logs in with"
  type        = string
  default     = "dex"
}

variable "dex_redirect_uri" {
  description = "Dex's callback URL (<dex issuer>/callback)"
  type        = string
}

variable "connector_name" {
  description = "Name of the Dex connector (the login button Dex shows)"
  type        = string
  default     = "Lab account"
}

variable "identity_providers" {
  description = <<-EOT
    Upstream identity providers Keycloak brokers, keyed by alias. type:
    "google" (hosted_domain restricts to a Workspace domain), "github", or
    "oidc" (authorization_url, token_url, issuer and jwks_url all required;
    signatures are always validated).

    trust_email: take the provider's email as verified. Default true for
    google and github (they verify), false for oidc -- set it only for an
    issuer that verifies emails. Dex refuses unverified ones, so users of an
    untrusted provider cannot log in until Keycloak verifies their address
    itself: set verify_email and smtp.

    link_existing_by_email (default false, per provider): a first login whose
    email matches an existing user -- a pre-created superadmin, or someone an
    admin added -- becomes that user, with no confirmation. Whoever controls
    the provider can then claim any address it can assert, superadmins
    included, so enable it only for a provider you control whose emails are
    verified and bounded (Google with your Workspace hosted_domain), and
    never for one a tenant brings. It requires trust_email.
  EOT
  type = map(object({
    type                   = string
    client_id              = string
    client_secret          = string
    display_name           = optional(string)
    hosted_domain          = optional(string, "")
    authorization_url      = optional(string, "")
    token_url              = optional(string, "")
    issuer                 = optional(string, "")
    jwks_url               = optional(string, "")
    default_scopes         = optional(string, "openid email profile")
    trust_email            = optional(bool)
    link_existing_by_email = optional(bool, false)
  }))
  default   = {}
  sensitive = true

  validation {
    condition     = alltrue([for p in values(var.identity_providers) : contains(["google", "github", "oidc"], p.type)])
    error_message = "identity_providers[*].type must be google, github, or oidc."
  }
  validation {
    condition     = alltrue([for p in values(var.identity_providers) : p.type != "oidc" || (p.authorization_url != "" && p.token_url != "" && p.issuer != "" && p.jwks_url != "")])
    error_message = "An oidc identity provider needs authorization_url, token_url, issuer and jwks_url: without issuer and jwks_url its tokens would be neither issuer-checked nor signature-checked."
  }
  validation {
    condition     = alltrue([for p in values(var.identity_providers) : !p.link_existing_by_email || coalesce(p.trust_email, p.type != "oidc")])
    error_message = "link_existing_by_email needs trust_email: linking on an unverified email hands the matching account to whoever asserted it."
  }
}

variable "brute_force_detection" {
  description = "Keycloak's brute-force protection for the realm's password logins (local users): temporary lockouts that grow with repeated failures. max_login_failures before the first lockout."
  type = object({
    enabled                  = optional(bool, true)
    max_login_failures       = optional(number, 10)
    wait_increment_seconds   = optional(number, 60)
    max_failure_wait_seconds = optional(number, 900)
    failure_reset_seconds    = optional(number, 43200)
  })
  default = {}
}

variable "sso_session_idle_timeout" {
  description = "How long a realm login lasts unused (Keycloak's SSO Session Idle; its default is 30m). Dex's refresh tokens from the realm end with it, and relying parties refresh through Dex (oauth2-proxy every auth.session_refresh, 1h by default; JupyterHub before spawns), so keep it above the longest refresh interval or users are sent back to log in."
  type        = string
  default     = "4h"
}

variable "sso_session_max_lifespan" {
  description = "The longest a realm login lasts however much it is used (SSO Session Max): after it, refreshes fail and users log in again. Match the relying parties' own caps (oauth2-proxy's session_lifetime, JupyterHub's cookie, both a day by default)."
  type        = string
  default     = "24h"
}

variable "smtp" {
  description = "Outgoing mail for the realm (address verification, verify_email). username empty: no SMTP authentication; otherwise smtp_password is its password."
  type = object({
    host              = string
    port              = optional(number, 587)
    from              = string
    from_display_name = optional(string, "")
    reply_to          = optional(string, "")
    starttls          = optional(bool, true)
    ssl               = optional(bool, false)
    username          = optional(string, "")
  })
  default = null
}

variable "smtp_password" {
  description = "Password for smtp.username"
  type        = string
  default     = ""
  sensitive   = true
}

variable "verify_email" {
  description = "Make users with an unverified email -- those from an identity provider without trust_email -- verify it by mail before their login completes. Needs smtp."
  type        = bool
  default     = false

  validation {
    condition     = !var.verify_email || var.smtp != null
    error_message = "verify_email sends mail: set smtp."
  }
}

variable "local_users" {
  description = "Users with a password in the realm itself (CI and laptops), keyed by a short name: email, password, and the group paths they start in (e.g. \"/lab/authors\"). Their memberships are added, never removed, by tofu, so admins can change them at runtime."
  type = map(object({
    email      = string
    password   = string
    first_name = optional(string, "")
    last_name  = optional(string, "")
    groups     = optional(list(string), [])
  }))
  default   = {}
  sensitive = true
}
