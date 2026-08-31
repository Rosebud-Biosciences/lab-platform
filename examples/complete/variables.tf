variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name (drives cluster/VPC naming)"
  type        = string
  default     = "prod"
}

# ------------------------------------------------------------------------------
# PRIVATE ACCESS (Tailscale)
# ------------------------------------------------------------------------------

variable "tailscale_tailnet" {
  description = "Tailscale tailnet (e.g. example.com or the org's *.ts.net). '-' uses the OAuth client default."
  type        = string
  default     = "-"
}

variable "tailscale_dns_suffix" {
  description = "MagicDNS suffix for the tailnet (e.g. tailXXXX.ts.net), used to build private URLs"
  type        = string
  default     = ""
}

variable "tailscale_oauth_client_id" {
  description = "Tailscale OAuth client ID (owns tag:k8s-operator and tag:subnet-router)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "Tailscale OAuth client secret"
  type        = string
  default     = ""
  sensitive   = true
}

# ------------------------------------------------------------------------------
# PUBLIC WEBAPP
# ------------------------------------------------------------------------------

variable "webapp_image" {
  description = "Container image (repository:tag) for the webapp"
  type        = string
}

variable "webapp_public_host" {
  description = "Public hostname served by the ALB (e.g. app.example.com)"
  type        = string
  default     = ""
}

variable "webapp_acm_certificate_arn" {
  description = "ACM certificate ARN for the webapp ALB HTTPS listener"
  type        = string
  default     = ""
}

variable "webapp_route53_zone_id" {
  description = "Route53 hosted zone id for webapp_public_host (empty skips the alias record)"
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# DATABASES (bring your own Postgres; see examples/preview for Neon branching)
# ------------------------------------------------------------------------------

variable "app_database_url" {
  description = "Application DATABASE_URL published to the webapp/Ray services"
  type        = string
  default     = ""
  sensitive   = true
}

variable "dagster_db" {
  description = "Dagster metadata Postgres connection"
  type = object({
    host     = string
    name     = string
    user     = string
    password = string
  })
  default = {
    host     = ""
    name     = ""
    user     = ""
    password = ""
  }
  sensitive = true
}

variable "mlflow_db" {
  description = "MLflow tracking Postgres connection"
  type = object({
    host     = string
    name     = string
    user     = string
    password = string
  })
  default = {
    host     = ""
    name     = ""
    user     = ""
    password = ""
  }
  sensitive = true
}

variable "jupyterhub_user_password" {
  description = "Shared password for JupyterHub dummy auth"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project   = "lab-platform"
    ManagedBy = "terraform"
  }
}
