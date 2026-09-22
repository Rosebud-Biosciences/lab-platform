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

# ------------------------------------------------------------------------------
# Identity and tenants (tenants.tf)
# ------------------------------------------------------------------------------

variable "enable_keycloak" {
  description = "Keycloak behind Dex with the lab / acme tenants and six local users (tenants.tf). false keeps Dex's password DB and mock connector only and drops the tenants, for 8 GiB laptops."
  type        = bool
  default     = true
}

variable "keycloak_node_port" {
  description = "NodePort (mapped to localhost by kind-config.yaml) tofu configures the realm through"
  type        = number
  default     = 30080
}

variable "postgres_node_port" {
  description = "NodePort (mapped to localhost by kind-config.yaml) tofu creates the notebook group roles through"
  type        = number
  default     = 30432
}

variable "kind_users_password" {
  description = "Password of the six local Keycloak users (sam, ann, alice, bob, cara, dan @example.com)"
  type        = string
  default     = "password"
  sensitive   = true
}

variable "tenants" {
  description = "The tenancy matrix (modules/tenancy). verify-tenants.sh also plans an invalid one to show the refusal."
  type        = any
  default = {
    lab = {
      trust    = "internal"
      groups   = { authors = {}, pipelines = {} }
      services = { ray = "isolated", argo = "shared", dagster = "shared", mlflow = "shared", jupyterhub = "shared", webapp = "shared" }
    }
    acme = {
      trust    = "external"
      groups   = { research = {} }
      services = { ray = "isolated", argo = "isolated", dagster = "isolated", mlflow = "shared", jupyterhub = "shared", webapp = "shared" }
      data     = { database = "own_database", bucket = "own" }
    }
  }
}

variable "acme_s3_access_key" {
  description = "acme's SeaweedFS identity (prereqs.sh ACME_S3_ACCESS_KEY): Read/Write/List on bucket tenant-acme only"
  type        = string
  default     = "acme"
}

variable "acme_s3_secret_key" {
  description = "acme's SeaweedFS secret key (prereqs.sh ACME_S3_SECRET_KEY)"
  type        = string
  default     = "acme12345678"
  sensitive   = true
}
