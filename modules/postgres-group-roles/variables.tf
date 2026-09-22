variable "groups" {
  description = "Group paths (/<tenant>/<group>) that get a login role nb_<tenant>__<group>. The app's row-level security maps the role back to the path (app_viewer_groups() in the template's migration 0004)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for g in var.groups : can(regex("^/[a-z]([a-z0-9_]{0,19}[a-z0-9])?/[a-z]([a-z0-9_]{0,19}[a-z0-9])?$", g)) && !strcontains(g, "__")])
    error_message = "groups are /<tenant>/<group> paths with slugs ^[a-z]([a-z0-9_]{0,19}[a-z0-9])?$ and no \"__\": a trailing underscore would make nb_<tenant>__<group> read back as another group."
  }
}

variable "member_of" {
  description = "NOLOGIN roles every group role is granted (the app's app_notebook, whose policies do the scoping)"
  type        = list(string)
  default     = ["app_notebook"]
}

variable "connection" {
  description = "Where the roles connect, for the URLs in the output (host, port, database, sslmode)"
  type = object({
    host     = string
    port     = optional(number, 5432)
    database = string
    sslmode  = optional(string, "require")
  })
}

variable "connection_limit" {
  description = "Connection limit per role (-1 = none)"
  type        = number
  default     = 10
}
