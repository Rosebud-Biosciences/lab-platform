# ------------------------------------------------------------------------------
# STATE BACKEND
# ------------------------------------------------------------------------------

variable "state_bucket_name" {
  description = "Name of the S3 bucket that stores Terraform state (globally unique)"
  type        = string
}

variable "lock_table_name" {
  description = "Name of the DynamoDB table used for state locking"
  type        = string
  default     = "terraform-locks"
}

variable "state_noncurrent_expiration_days" {
  description = "Days after which noncurrent state versions are expired"
  type        = number
  default     = 180
}

variable "state_bucket_prevent_destroy" {
  description = "Attach a Deny s3:DeleteBucket policy to the state bucket so no principal can delete it without first removing the policy"
  type        = bool
  default     = true
}

variable "lock_table_deletion_protection" {
  description = "Enable DynamoDB deletion protection on the lock table"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to created resources"
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# GITHUB OIDC
# ------------------------------------------------------------------------------

variable "github_owner" {
  description = "GitHub org/user that owns the CI and preview repositories"
  type        = string
  default     = ""
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC identity provider. Set false to reuse an existing one via github_oidc_provider_arn."
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "ARN of an existing GitHub Actions OIDC provider (used when create_github_oidc_provider is false)"
  type        = string
  default     = ""
}

# --- CI deployer role (ECR push + EKS describe) -------------------------------

variable "enable_ci_deployer_role" {
  description = "Create the GitHub Actions CI role (ECR push + eks:DescribeCluster)"
  type        = bool
  default     = true
}

variable "ci_deployer_role_name" {
  description = "Name for the CI deployer IAM role"
  type        = string
  default     = "github-actions-ci-deployer"
}

variable "ci_repos" {
  description = "GitHub repositories (name only) whose Actions may assume the CI deployer role"
  type        = list(string)
  default     = []
}

variable "ci_ecr_repositories" {
  description = "ECR repository names the CI deployer may push to"
  type        = list(string)
  default     = []
}

variable "cluster_name_pattern" {
  description = "EKS cluster name pattern the roles may eks:DescribeCluster (e.g. eks-*)"
  type        = string
  default     = "eks-*"
}

# --- Preview deployer role (Terraform state + scoped IAM/S3/KMS) --------------

variable "enable_preview_deployer_role" {
  description = "Create the least-privilege GitHub Actions preview role that runs the preview Terraform stack"
  type        = bool
  default     = true
}

variable "preview_deployer_role_name" {
  description = "Name for the preview deployer IAM role"
  type        = string
  default     = "github-actions-preview-deployer"
}

variable "preview_repos" {
  description = "GitHub repositories (name only) whose Actions may assume the preview deployer role"
  type        = list(string)
  default     = []
}

variable "preview_state_key_prefix" {
  description = "State object key prefix the preview role may read and write (its workspaces' state); it reads no other state but preview_state_read_keys"
  type        = string
  default     = "preview/*"
}

variable "preview_state_read_keys" {
  description = "State objects outside preview_state_key_prefix the preview role may read: the preview stack's own backend `key` when it lies outside the prefix (e.g. [\"template-app/terraform.tfstate\"]) -- its default-workspace object, which `tofu init` reads before a preview workspace is selected, and which previews never write. Never another stack's key: state holds that stack's secrets."
  type        = list(string)
  default     = []
}

variable "preview_iam_path" {
  description = "IAM path of every role and policy the preview stack creates (the modules' iam_path). The preview role may create and change roles and policies under it only -- nothing of prod's, which must never use it -- and only roles carrying the preview permissions boundary."
  type        = string
  default     = "/preview/"

  validation {
    condition     = can(regex("^/([A-Za-z0-9_+=,.@-]+/)+$", var.preview_iam_path))
    error_message = "preview_iam_path is an IAM path other than the root: it starts and ends with /, e.g. /preview/."
  }
}

variable "preview_attachable_policy_arns" {
  description = "Policies outside preview_iam_path that the preview role may also attach to preview roles (e.g. a shared read-only policy on prod data). The permissions boundary still caps what they grant."
  type        = list(string)
  default     = []
}

variable "preview_boundary_resources" {
  description = "Resources the preview permissions boundary allows its actions on. Narrow it to your data buckets, table buckets, KMS keys and ECR repositories to cap previews further."
  type        = list(string)
  default     = ["*"]
}

variable "preview_boundary_extra_actions" {
  description = "Actions beyond object-level S3, the S3 Tables data plane, KMS data keys and ECR pulls that preview workloads may be granted (e.g. \"secretsmanager:GetSecretValue\"). Never IAM or STS."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.preview_boundary_extra_actions : !can(regex("^(iam|sts|organizations):", lower(a))) && a != "*"])
    error_message = "preview_boundary_extra_actions must not include iam:, sts:, organizations: actions or *: a preview role that can use them can escape the boundary."
  }
}

variable "preview_ephemeral_bucket_pattern" {
  description = "S3 bucket name pattern for per-preview ephemeral buckets the role may create/destroy"
  type        = string
  default     = "preview-processeddata-*"
}

variable "preview_ecr_repositories" {
  description = "ECR repository names whose preview-tagged images the preview role may prune on teardown"
  type        = list(string)
  default     = []
}

variable "preview_table_bucket_arns" {
  description = "S3 Tables table-bucket ARNs in which the preview role may create/destroy per-preview Iceberg namespaces (aws/iceberg-branches). Empty skips the s3tables statements."
  type        = list(string)
  default     = []
}

variable "preview_iceberg_namespace_pattern" {
  description = "Namespace pattern (s3tables:namespace condition) scoping which tables the preview role may drop during teardown — must match your preview names (e.g. pr*) and never prod namespaces"
  type        = string
  default     = "pr*"
}

variable "preview_resource_tag_key" {
  description = "Tag key gating the preview role's KMS key mutations (defence-in-depth)"
  type        = string
  default     = "Environment"
}

variable "preview_resource_tag_value" {
  description = "Tag value gating the preview role's KMS key mutations"
  type        = string
  default     = "preview"
}

# ------------------------------------------------------------------------------
# HUMAN OPERATOR (MFA-gated admin role + guardrails; see operator.tf)
# ------------------------------------------------------------------------------

variable "enable_operator_admin_role" {
  description = "Create the MFA-gated operator role and its guardrail policy. Requires operator_principal_arns. See docs/operator-access.md."
  type        = bool
  default     = false
}

variable "operator_admin_role_name" {
  description = "Name for the operator admin IAM role; the guardrail policy is named <role>-guardrails"
  type        = string
  default     = "operator-admin"
}

variable "operator_principal_arns" {
  description = "IAM user/role ARNs allowed to assume the operator role (with a recent MFA challenge). The module does not manage these identities."
  type        = list(string)
  default     = []
}

variable "operator_admin_policy_arns" {
  description = "Managed policy ARNs attached to the operator role. AdministratorAccess by default; scope down once you know what your stacks call. The guardrail Deny policy is attached regardless."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}

variable "operator_mfa_max_age" {
  description = "Seconds since the MFA challenge within which the operator role may be assumed. Bounds how long an MFA'd session stays useful for stepping up."
  type        = number
  default     = 3600
}

variable "operator_admin_session_duration" {
  description = "Maximum operator role session length in seconds (3600-43200). Long enough for a full cluster apply, because credentials expiring mid-apply is how state drifts from reality."
  type        = number
  default     = 14400

  validation {
    condition     = var.operator_admin_session_duration >= 3600 && var.operator_admin_session_duration <= 43200
    error_message = "operator_admin_session_duration must be between 3600 and 43200 seconds (IAM's bounds for max_session_duration)."
  }
}
