variable "tenants" {
  description = <<-EOT
    The platform's tenants. Per tenant:
      trust     "internal" (the lab's own teams) or "external" (another
                organization): external tenants may only share a service
                that isolates tenants inside one instance (webapp,
                jupyterhub, mlflow); the plan fails otherwise.
      groups    its groups (/<tenant>/<group>); data = false skips the group's
                Postgres role.
      services  per service "shared" (the platform's instance, isolated inside
                where the service can), "isolated" (the tenant's own stamp)
                or "off".
      dagster_image  the tenant's code: a code location in the shared
                Dagster, or its stamp's user code (empty: the stamp's
                hello-world location).
      data      database: "shared" (the app database, RLS) | "own_database";
                bucket: "shared_prefix" (s3://<shared>/tenants/<tenant>/) |
                "own" -- consumed by aws/tenant-data.
  EOT
  type = map(object({
    trust = optional(string, "internal")
    groups = optional(map(object({
      data = optional(bool, true)
    })), {})
    services = optional(object({
      webapp     = optional(string, "shared")
      jupyterhub = optional(string, "shared")
      mlflow     = optional(string, "shared")
      dagster    = optional(string, "shared")
      ray        = optional(string, "off")
      argo       = optional(string, "off")
    }), {})
    dagster_image = optional(string, "")
    data = optional(object({
      database = optional(string, "shared")
      bucket   = optional(string, "shared_prefix")
    }), {})
  }))

  validation {
    condition     = alltrue([for t in values(var.tenants) : contains(["internal", "external"], t.trust)])
    error_message = "tenants[*].trust must be internal or external."
  }
  validation {
    condition     = alltrue(flatten([for t in values(var.tenants) : [for mode in values(t.services) : contains(["shared", "isolated", "off"], mode)]]))
    error_message = "tenants[*].services values must be shared, isolated or off."
  }
  validation {
    condition = alltrue(flatten([
      for t, v in var.tenants : concat(
        [can(regex("^[a-z]([a-z0-9_]{0,19}[a-z0-9])?$", t)) && !strcontains(t, "__") && !contains(["admins", "platform-admins"], t)],
        [for g in keys(v.groups) : can(regex("^[a-z]([a-z0-9_]{0,19}[a-z0-9])?$", g)) && !strcontains(g, "__") && g != "admins"],
      )
    ]))
    error_message = "Tenant and group slugs match ^[a-z]([a-z0-9_]{0,19}[a-z0-9])?$ without \"__\" (nb_<tenant>__<group> must read back unambiguously); \"admins\" is reserved."
  }
  validation {
    condition     = alltrue([for t in values(var.tenants) : contains(["shared", "own_database"], t.data.database) && contains(["shared_prefix", "own"], t.data.bucket)])
    error_message = "tenants[*].data.database is shared | own_database; data.bucket is shared_prefix | own."
  }
}

variable "superadmin_group" {
  description = "The superadmins' group (modules/keycloak-realm superadmin_group); admitted everywhere"
  type        = string
  default     = "/platform-admins"
}

variable "platform_prefix" {
  description = "name_prefix of the platform's shared workloads instance (its namespaces are <prefix><service>)"
  type        = string
  default     = ""
}

variable "platform_mlflow_oidc" {
  description = "Whether the shared MLflow runs its own OIDC (auth.mlflow_mode = \"oidc\"): only then can external tenants share it (per-experiment permissions) and do tenants get MLflow service accounts"
  type        = bool
  default     = true
}

variable "tenant_identity" {
  description = "Per tenant, the identity its compute runs with (aws/tenant-data's IRSA role annotations, or static keys on kind): service_account_annotations, env, secret_env"
  type = map(object({
    service_account_annotations = optional(map(string), {})
    env                         = optional(map(string), {})
    secret_env                  = optional(map(string), {})
  }))
  default = {}
}

variable "group_secret_env" {
  description = "Per group path, extra secrets for its notebook profile (e.g. DATABASE_URL from modules/postgres-group-roles credentials)"
  type        = map(map(string))
  default     = {}
}

variable "stamp_prefix" {
  description = "Format of a tenant stamp's name_prefix (%s = tenant)"
  type        = string
  default     = "t-%s-"
}
