variable "kubeconfig_path" {
  description = "Kubeconfig to reach the cluster"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubeconfig context (kind names it kind-<cluster name>)"
  type        = string
  default     = "kind-lab-platform"
}

variable "name_prefix" {
  description = "Optional prefix, as a preview would use (\"pr7-\"); empty for the base names"
  type        = string
  default     = ""
}

variable "webapp_image" {
  description = "Any HTTP container that answers 200 on / -- the point is the wiring, not the app"
  type        = string
  default     = "nginxinc/nginx-unprivileged:1.29-alpine"
}

variable "webapp_container_port" {
  description = "Port webapp_image listens on"
  type        = number
  default     = 8080
}

variable "enable_jupyterhub" {
  description = "Also deploy JupyterHub (adds ~1.5 GiB of pods; off by default so the example fits a CI runner)"
  type        = bool
  default     = false
}

variable "jupyterhub_user_password" {
  description = "Shared password for the dummy authenticator"
  type        = string
  default     = "notebooks"
  sensitive   = true
}

variable "jupyterhub_storage_class" {
  description = "StorageClass for the shared volume. kind's default local-path class is RWO but works for RWX claims on a single node."
  type        = string
  default     = "standard"
}

# --- Dex's local user (scripts/verify.sh logs in as it) -----------------------

variable "dex_admin_email" {
  description = "Email of the password-DB user in Dex"
  type        = string
  default     = "admin@example.com"
}

variable "dex_admin_password_hash" {
  description = "bcrypt hash of that user's password. The default is Dex's documented example hash for the word \"password\" (verify.sh DEX_PASSWORD)."
  type        = string
  default     = "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W"
  sensitive   = true
}

# --- The local data backend (must match what scripts/prereqs.sh created) ----

variable "s3_endpoint" {
  description = "In-cluster S3 endpoint of the local object store (SeaweedFS from scripts/prereqs.sh)"
  type        = string
  default     = "http://seaweedfs.seaweedfs.svc.cluster.local:8333"
}

variable "s3_access_key" {
  description = "Object store access key (scripts/prereqs.sh S3_ACCESS_KEY)"
  type        = string
  default     = "seaweedfs"
}

variable "s3_secret_key" {
  description = "Object store secret key (scripts/prereqs.sh S3_SECRET_KEY)"
  type        = string
  default     = "seaweedfs12345"
  sensitive   = true
}

variable "postgres_host" {
  description = "In-cluster Postgres host"
  type        = string
  default     = "postgres.postgres.svc.cluster.local"
}

variable "postgres_user" {
  description = "Postgres superuser (scripts/prereqs.sh POSTGRES_USER)"
  type        = string
  default     = "postgres"
}

variable "postgres_password" {
  description = "Postgres password (scripts/prereqs.sh POSTGRES_PASSWORD)"
  type        = string
  default     = "postgres"
  sensitive   = true
}
