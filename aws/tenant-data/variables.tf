variable "tenant" {
  description = "Tenant slug (modules/tenancy)"
  type        = string

  validation {
    condition     = can(regex("^[a-z]([a-z0-9_]{0,19}[a-z0-9])?$", var.tenant)) && !strcontains(var.tenant, "__")
    error_message = "tenant is a slug: ^[a-z]([a-z0-9_]{0,19}[a-z0-9])?$ without \"__\" (modules/tenancy's rule)."
  }
}

variable "name_prefix" {
  description = "Prefix for AWS resource names (role, bucket, policy)"
  type        = string
  default     = ""
}

variable "oidc_provider_arn" {
  description = "The cluster's IAM OIDC provider ARN (aws/eks-platform or aws/oidc-provider)"
  type        = string
}

variable "oidc_issuer" {
  description = "The cluster's OIDC issuer URL (with or without https://)"
  type        = string
}

variable "service_accounts" {
  description = "The tenant's Kubernetes ServiceAccounts, as namespace/name (its stamps' workloads, its JupyterHub group profiles jupyterhub/jh-<tenant>-<group>, its Dagster code location dagster/dagster-<tenant>)"
  type        = list(string)

  validation {
    condition     = alltrue([for s in var.service_accounts : can(regex("^[a-z0-9-]+/[a-z0-9-]+$", s))])
    error_message = "service_accounts entries are namespace/name."
  }
}

variable "bucket" {
  description = "\"shared_prefix\": the tenant gets s3://<shared_bucket>/tenants/<tenant>/ and nothing else of that bucket. \"own\": a bucket of its own (aws/s3-bucket, its own KMS key)."
  type        = string
  default     = "shared_prefix"

  validation {
    condition     = contains(["shared_prefix", "own"], var.bucket)
    error_message = "bucket is shared_prefix or own."
  }
}

variable "shared_bucket_arn" {
  description = "ARN of the shared data bucket (bucket = \"shared_prefix\")"
  type        = string
  default     = ""
}

variable "shared_bucket_kms_key_arn" {
  description = "KMS key of the shared bucket, if it is SSE-KMS encrypted"
  type        = string
  default     = ""
}

variable "own_bucket_prevent_destroy" {
  description = "Guard the tenant's own bucket against tofu destroy"
  type        = bool
  default     = true
}

variable "database" {
  description = "\"shared\": the tenant reads the app database through row-level security (modules/postgres-group-roles). \"own_database\": a database and owner role of its own on the caller's Postgres (its stamps' Dagster and data)."
  type        = string
  default     = "shared"

  validation {
    condition     = contains(["shared", "own_database"], var.database)
    error_message = "database is shared or own_database."
  }
}

variable "database_connection" {
  description = "Where an own database lives, for the URL output (host, port, sslmode)"
  type = object({
    host    = string
    port    = optional(number, 5432)
    sslmode = optional(string, "require")
  })
  default = null
}

variable "tags" {
  description = "Tags for AWS resources"
  type        = map(string)
  default     = {}
}
