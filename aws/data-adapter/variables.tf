variable "cluster_name" {
  description = "Identifier of the cluster the pods run on, used only to name the IAM roles (<cluster_name>-<name_prefix><service>-sa). Any string; it need not be an EKS cluster."
  type        = string
}

variable "name_prefix" {
  description = "Same name_prefix as the modules/workloads instance these roles serve; the trusted <namespace>/<serviceaccount> subjects are derived from it."
  type        = string
  default     = ""
}

variable "webapp_app_name" {
  description = "Same webapp_app_name as the workloads instance (its namespace and ServiceAccount carry this name)."
  type        = string
  default     = "webapp"
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider the roles trust: the EKS cluster's (module.platform.oidc_provider_arn) or a foreign cluster's registered through aws/oidc-provider."
  type        = string
}

variable "binding" {
  description = <<-EOT
    How pods present the trusted token:
      webhook    the cluster injects it (EKS IRSA via the pod identity
                 webhook): workloads gets an eks.amazonaws.com/role-arn SA
                 annotation and nothing in the pod spec.
      projected  any cluster: workloads mounts a projected ServiceAccount
                 token with audience sts.amazonaws.com and the SDK reads
                 AWS_ROLE_ARN + AWS_WEB_IDENTITY_TOKEN_FILE from env. Use
                 with aws/oidc-provider for kind/GKE/AKS/on-prem compute.
  EOT
  type        = string
  default     = "webhook"

  validation {
    condition     = contains(["webhook", "projected"], var.binding)
    error_message = "binding must be 'webhook' or 'projected'."
  }
}

variable "projected_token_mount_path" {
  description = "Where the projected token is mounted in projected binding (the file is <mount_path>/token)."
  type        = string
  default     = "/var/run/secrets/workload-identity"
}

variable "region" {
  description = "AWS region the data lives in, published to pods as AWS_REGION"
  type        = string
}

# ------------------------------------------------------------------------------
# Which services get a role (mirror the workloads toggles)
# ------------------------------------------------------------------------------

variable "enable_webapp" {
  description = "Create the webapp role"
  type        = bool
  default     = false
}

variable "enable_dagster" {
  description = "Create the Dagster role"
  type        = bool
  default     = false
}

variable "enable_ray" {
  description = "Create the Ray role"
  type        = bool
  default     = false
}

variable "enable_argo_workflows" {
  description = "Create the Argo Workflows role (workflow pods in the environment's argo namespace)"
  type        = bool
  default     = false
}

variable "enable_mlflow" {
  description = "Create the MLflow role and its artifact-bucket policy"
  type        = bool
  default     = false
}

variable "enable_jupyterhub" {
  description = "Create the JupyterHub single-user role"
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# What each role may reach
# ------------------------------------------------------------------------------

variable "webapp_policy_arns" {
  description = "IAM policy ARNs attached to the webapp role (e.g. a bucket's get_arn)"
  type        = map(string)
  default     = {}
}

variable "dagster_policy_arns" {
  description = "IAM policy ARNs attached to the Dagster role"
  type        = map(string)
  default     = {}
}

variable "ray_policy_arns" {
  description = "IAM policy ARNs attached to the Ray and Argo roles (pipeline compute)"
  type        = map(string)
  default     = {}
}

variable "jupyterhub_policy_arns" {
  description = "IAM policy ARNs attached to the JupyterHub single-user role, on top of jupyterhub_s3_read_only"
  type        = map(string)
  default     = {}
}

variable "jupyterhub_s3_read_only" {
  description = "Attach the AWS managed AmazonS3ReadOnlyAccess policy to the JupyterHub single-user role: read on every bucket in the account. Off by default; grant specific buckets through jupyterhub_policy_arns."
  type        = bool
  default     = false
}

variable "mlflow_artifact_bucket" {
  description = "Name of the S3 bucket for MLflow artifacts (required when enable_mlflow)"
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_mlflow || var.mlflow_artifact_bucket != ""
    error_message = "mlflow_artifact_bucket is required when enable_mlflow is true."
  }
}

variable "mlflow_artifact_bucket_arn" {
  description = "ARN of the MLflow artifact bucket (the tracking-server policy is scoped to it)"
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_mlflow || var.mlflow_artifact_bucket_arn != ""
    error_message = "mlflow_artifact_bucket_arn is required when enable_mlflow is true."
  }
}

variable "mlflow_artifact_prefix" {
  description = "Key prefix inside the artifact bucket (no leading slash). Empty uses the bucket root."
  type        = string
  default     = ""
}

variable "mlflow_artifact_kms_key_arn" {
  description = "KMS key encrypting the artifact bucket, if customer-managed (aws/s3-bucket's aws_kms_key_arn); grants the MLflow role decrypt/encrypt on it. Empty for SSE-S3."
  type        = string
  default     = ""
}

variable "enable_ecr_pull" {
  description = "Let the Ray, Argo and Dagster roles pull from this account's ECR repositories (needed when pods pull private images with their own credentials rather than the node's)"
  type        = bool
  default     = true
}

variable "iam_path" {
  description = "IAM path of the roles and policies. A preview's go under aws/bootstrap's preview_iam_path (/preview/), which the preview role is confined to."
  type        = string
  default     = "/"

  validation {
    condition     = can(regex("^/([A-Za-z0-9_+=,.@-]+/)*$", var.iam_path))
    error_message = "iam_path starts and ends with /, e.g. / or /preview/."
  }
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the roles. A preview's must carry aws/bootstrap's preview_permissions_boundary_arn: the preview role may create no role without it."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every IAM resource"
  type        = map(string)
  default     = {}
}
