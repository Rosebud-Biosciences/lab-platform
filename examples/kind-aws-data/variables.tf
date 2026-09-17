variable "region" {
  description = "AWS region for the data (bucket, OIDC discovery bucket, roles)"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "kind cluster name (kubeconfig context kind-<name>; also the IAM role name prefix and the discovery prefix)"
  type        = string
  default     = "lab-platform-aws"
}

variable "kubeconfig_path" {
  description = "Kubeconfig to reach the kind cluster"
  type        = string
  default     = "~/.kube/config"
}

variable "name_prefix" {
  description = "Optional prefix, as a preview would use (\"pr7-\"); empty for the base names"
  type        = string
  default     = ""
}

# --- Identity bridge --------------------------------------------------------

variable "oidc_bucket_name" {
  description = "Public-read bucket hosting the kind cluster's OIDC discovery document (see aws/oidc-provider). Must be globally unique and DNS-safe without dots, e.g. lab-kind-oidc-<account id>. Empty means static keys instead (see README)."
  type        = string
  default     = ""
}

variable "jwks_json" {
  description = "The cluster's JWKS, `kubectl get --raw /openid/v1/jwks` (scripts/kind-up.sh writes jwks.json; pass -var jwks_json=\"$(cat jwks.json)\"). Required with oidc_bucket_name."
  type        = string
  default     = ""

  validation {
    condition     = var.oidc_bucket_name == "" || var.jwks_json != ""
    error_message = "jwks_json is required when oidc_bucket_name is set."
  }
}

variable "static_aws_access_key_id" {
  description = "Fallback when no issuer is hosted (oidc_bucket_name empty): an IAM user's access key, delivered to pods as a Secret. Rotation is yours."
  type        = string
  default     = ""
}

variable "static_aws_secret_access_key" {
  description = "Fallback secret key, see static_aws_access_key_id"
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.oidc_bucket_name != "" || (var.static_aws_access_key_id != "" && var.static_aws_secret_access_key != "")
    error_message = "Set oidc_bucket_name (federation) or both static_aws_* (fallback)."
  }
}

# --- Data -----------------------------------------------------------------

variable "data_bucket_name" {
  description = "Name for the S3 data bucket this example creates (empty derives lab-kind-data-<account id>)"
  type        = string
  default     = ""
}

variable "iceberg_table_bucket_arn" {
  description = "Existing S3 Tables table bucket to carve an ephemeral Iceberg namespace from (empty skips Iceberg)"
  type        = string
  default     = ""
}

# --- Compute (kind) --------------------------------------------------------

variable "webapp_image" {
  description = "Any HTTP container that answers 200 on /"
  type        = string
  default     = "nginxinc/nginx-unprivileged:1.29-alpine"
}

variable "webapp_container_port" {
  description = "Port webapp_image listens on"
  type        = number
  default     = 8080
}

variable "postgres_host" {
  description = "In-cluster Postgres host (scripts/prereqs.sh)"
  type        = string
  default     = "postgres.postgres.svc.cluster.local"
}

variable "postgres_user" {
  description = "Postgres superuser"
  type        = string
  default     = "postgres"
}

variable "postgres_password" {
  description = "Postgres password"
  type        = string
  default     = "postgres"
  sensitive   = true
}

variable "tags" {
  description = "Tags on every AWS resource"
  type        = map(string)
  default     = { Example = "kind-aws-data" }
}
