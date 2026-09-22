variable "namespace" {
  description = "Namespace for Keycloak"
  type        = string
  default     = "keycloak"
}

variable "create_namespace" {
  description = "Create the namespace (false to deploy into an existing one)"
  type        = bool
  default     = true
}

variable "release_name" {
  description = "Helm release name; also the chart's fullname, so the HTTP Service is <release_name>-http"
  type        = string
  default     = "keycloak"
}

variable "chart_version" {
  description = "codecentric/keycloakx Helm chart version"
  type        = string
  default     = "7.3.2"
}

variable "chart_repository" {
  description = "Helm repository holding the keycloakx chart"
  type        = string
  default     = "https://codecentric.github.io/helm-charts"
}

variable "image_tag" {
  description = "quay.io/keycloak/keycloak tag; empty uses the chart's (26.7.4 for chart 7.3.2). Fine-grained admin permissions v2 need >= 26.2."
  type        = string
  default     = ""
}

variable "hostname" {
  description = <<-EOT
    Keycloak's public base URL (hostname v2: scheme, host, optional port, no
    path), e.g. "https://id.example.com". Tokens carry it as their issuer
    origin, so browsers AND pods must reach Keycloak at this URL (on kind:
    the in-cluster Service URL; on a tailnet-only cluster: the private
    Ingress hostname plus pod DNS for it, docs/auth.md). Requests arriving
    under another name (a NodePort, a port-forward) are answered as this
    hostname when backchannel_dynamic is set.
  EOT
  type        = string

  validation {
    condition     = can(regex("^https?://[^/]+$", var.hostname))
    error_message = "hostname is a base URL without a path, e.g. https://id.example.com."
  }
}

variable "backchannel_dynamic" {
  description = "Let back-channel requests (token exchange, the admin API) use the host they arrive on, so tofu can configure the realm through a NodePort or port-forward while browsers use hostname (KC_HOSTNAME_BACKCHANNEL_DYNAMIC)"
  type        = bool
  default     = true
}

variable "proxy_headers" {
  description = "Which proxy headers Keycloak trusts for the client's scheme and host: \"xforwarded\" (ingress-nginx, most controllers), \"forwarded\" (RFC 7239), or \"\" (none: Keycloak is reached directly)"
  type        = string
  default     = "xforwarded"

  validation {
    condition     = contains(["xforwarded", "forwarded", ""], var.proxy_headers)
    error_message = "proxy_headers must be xforwarded, forwarded, or empty."
  }
}

variable "database" {
  description = "External PostgreSQL for Keycloak's own state (users, groups, sessions, the realm). A database of its own, outside any preview branching: identity is global."
  type = object({
    host     = string
    port     = optional(number, 5432)
    name     = string
    username = string
    password = string
  })
  sensitive = true
}

variable "bootstrap_admin_client_id" {
  description = "Client id of the master-realm admin service account Keycloak creates on first start (client credentials, generated secret). modules/keycloak-realm's provider authenticates with it; there is no password-bearing admin user. Superadmins administer the platform realm from its own console (/admin/<realm>/console)."
  type        = string
  default     = "tofu-admin"
}

variable "service_type" {
  description = "Service type for Keycloak's HTTP port: ClusterIP, or NodePort to reach it from the machine running tofu (kind)"
  type        = string
  default     = "ClusterIP"

  validation {
    condition     = contains(["ClusterIP", "NodePort"], var.service_type)
    error_message = "service_type must be ClusterIP or NodePort."
  }
}

variable "node_port" {
  description = "Fixed node port for service_type = NodePort (e.g. one kind maps to the host)"
  type        = number
  default     = null
}

variable "ingress" {
  description = "Optional Ingress in front of Keycloak (host should match hostname). It serves paths only -- by default /realms/<realm> for each of realms (logins, token endpoints, the account console) and /resources (their assets) -- so neither the master realm nor the admin console and admin API are published with the logins; see admin_hostname / admin_ingress. paths replaces that list."
  type = object({
    enabled         = optional(bool, false)
    class_name      = optional(string, "")
    host            = optional(string, "")
    annotations     = optional(map(string), {})
    tls_secret_name = optional(string, "")
    realms          = optional(list(string), ["lab"])
    paths           = optional(list(string))
  })
  default = {}

  validation {
    condition     = !contains(var.ingress.realms, "master")
    error_message = "ingress.realms must not publish master: it holds the bootstrap admin; reach it on admin_hostname."
  }
}

variable "admin_hostname" {
  description = "Base URL of Keycloak's admin console and admin API (KC_HOSTNAME_ADMIN), e.g. https://keycloak-admin.<tailnet>.ts.net: a name only operators reach, served by admin_ingress. Empty: the admin console answers on hostname, reachable only where something routes /admin (in-cluster, a port-forward)."
  type        = string
  default     = ""

  validation {
    condition     = var.admin_hostname == "" || can(regex("^https?://[^/]+$", var.admin_hostname))
    error_message = "admin_hostname is a base URL without a path."
  }
}

variable "admin_ingress" {
  description = "Optional Ingress for admin_hostname (a private IngressClass, e.g. tailscale): serves everything, admin console included, on that host only"
  type = object({
    enabled         = optional(bool, false)
    class_name      = optional(string, "")
    host            = optional(string, "")
    annotations     = optional(map(string), {})
    tls_secret_name = optional(string, "")
  })
  default = {}
}

variable "extra_env" {
  description = "Extra Keycloak environment variables (KC_* options), merged over the module's"
  type        = map(string)
  default     = {}
}

variable "resources" {
  description = "Keycloak container resources"
  type        = any
  default = {
    requests = { cpu = "250m", memory = "768Mi" }
    limits   = { memory = "1536Mi" }
  }
}

variable "node_selector" {
  description = "Node selector for the Keycloak pod"
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the Keycloak pod"
  type        = list(any)
  default     = []
}

variable "extra_values" {
  description = "Extra Helm values documents, applied after the module's"
  type        = list(string)
  default     = []
}
