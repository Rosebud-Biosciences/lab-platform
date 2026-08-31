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
  description = "State object key prefix the preview role may write (least-privilege state scoping)"
  type        = string
  default     = "preview/*"
}

variable "preview_managed_role_pattern" {
  description = "IAM role name pattern the preview stack (workloads module) creates and the role may manage"
  type        = string
  default     = "eks-*"
}

variable "preview_managed_policy_patterns" {
  description = "IAM policy name patterns the preview stack creates and the role may manage (e.g. eks-*, bucket-preview-processeddata-*, iceberg-*)"
  type        = list(string)
  default     = ["eks-*", "bucket-preview-processeddata-*", "iceberg-*"]
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
  description = "S3 Tables table-bucket ARNs in which the preview role may create/destroy per-preview Iceberg namespaces (modules/iceberg-branches). Empty skips the s3tables statements."
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
