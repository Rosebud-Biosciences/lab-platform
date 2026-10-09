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

variable "github_owner_id" {
  description = "Numeric ID of github_owner (`gh api repos/<owner>/<repo> --jq .owner.id`); needed with github_repository_ids"
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[0-9]*$", var.github_owner_id))
    error_message = "github_owner_id is the owner's numeric ID, not its name."
  }
}

variable "github_repository_ids" {
  description = "Numeric IDs, by name, of the ci_repos / preview_repos whose Actions tokens carry GitHub's immutable subject (repo:OWNER@OWNER_ID/REPO@REPO_ID:...): every repository created, renamed or transferred since 2026-07-15, and older ones opted in (`gh api repos/<owner>/<repo>/actions/oidc/customization/sub` shows which). A listed repository is trusted under that subject only; an unlisted one under the name-only subject, which matches no immutable-format token."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for id in values(var.github_repository_ids) : can(regex("^[0-9]+$", id))])
    error_message = "github_repository_ids maps repository names to their numeric IDs (`gh api repos/<owner>/<repo> --jq .id`)."
  }
  validation {
    condition     = length(var.github_repository_ids) == 0 || var.github_owner_id != ""
    error_message = "github_repository_ids needs github_owner_id: the immutable subject names both."
  }
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

variable "enable_teardown_role" {
  description = "Create a role only teardown_repos' runs on teardown_ref may assume -- the nightly preview sweep, and the data jobs that write prod's trunk and pins (data-pull, tether-matrix) -- for what a pull_request run must not hold: e.g. deleting the stores a PR created, or pinning prod's data once data-access's protect_trunk fences the pull-request roles. It has no permissions of its own; the stack that owns the data attaches them."
  type        = bool
  default     = false
}

variable "teardown_role_name" {
  description = "Name for the teardown IAM role"
  type        = string
  default     = "github-actions-teardown"
}

variable "teardown_repos" {
  description = "GitHub repositories (name only) whose runs on teardown_ref may assume the teardown role"
  type        = list(string)
  default     = []
}

variable "teardown_ref" {
  description = "The one git ref whose runs may assume the teardown role (scheduled and dispatched runs of the default branch)"
  type        = string
  default     = "refs/heads/main"
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

variable "preview_boundary_access" {
  description = <<-EOT
    What preview roles may reach beyond what a preview owns. The boundary already allows each preview its ephemeral bucket (preview_ephemeral_bucket_pattern, in this account) and the KMS keys tagged preview_resource_tag_key = preview_resource_tag_value, reads in preview_table_bucket_arns and writes in its own Iceberg namespaces (preview_iceberg_namespace_pattern), and image pulls from preview_ecr_repositories (all of this account's repositories when that is empty). Everything else is listed here as ARNs -- S3 as bucket or bucket/prefix*, S3 Tables as bucket/table/<id>:
    read: stores previews read but never change (writable and deletable ARNs are readable too);
    write: where they may write -- tether mode's data prefixes and the prod tables they commit to (aws/data-access's prefixes and table_arns);
    delete: what they may delete -- tether mode's Lance working branches only (bucket/prefix*/_refs/branches/tether.ws.* and bucket/prefix*/tree/tether.ws.*);
    kms_key_arns: the keys of those stores;
    extra_action_resources: what preview_boundary_extra_actions apply to.
    Breaking from 0.2: this replaces preview_boundary_resources (["*"]), and a store not listed is out of every preview's reach.
  EOT
  type = object({
    read                   = optional(list(string), [])
    write                  = optional(list(string), [])
    delete                 = optional(list(string), [])
    kms_key_arns           = optional(list(string), [])
    extra_action_resources = optional(list(string), ["*"])
  })
  default = {}
}

variable "preview_boundary_federated_providers" {
  description = "IAM OIDC provider ARNs (your clusters' IRSA issuers) every preview role session must come through; any other session -- a role a PR made assumable from elsewhere -- is denied everything. Wildcards match: \"arn:aws:iam::<account>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/*\" admits every EKS cluster's issuer registered in this account and survives a cluster rebuild, where a cluster's own ARN changes with it. Only the account's admins can register issuers (the preview role cannot). Empty (default) skips the check."
  type        = list(string)
  default     = []
}

variable "preview_boundary_extra_actions" {
  description = "Actions beyond object-level S3, the S3 Tables data plane, KMS data keys and ECR pulls that preview workloads may be granted (e.g. \"secretsmanager:GetSecretValue\"), on preview_boundary_access.extra_action_resources. Never IAM or STS."
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
  description = "ECR repository names whose preview-tagged images the preview role may prune on teardown, and the only ones preview workloads may pull from (empty: every repository in this account)"
  type        = list(string)
  default     = []
}

variable "preview_table_bucket_arns" {
  description = "S3 Tables table-bucket ARNs in which the preview role may create/destroy per-preview Iceberg namespaces (aws/iceberg-branches), and preview workloads may read every table and write those in preview_iceberg_namespace_pattern. Empty skips the s3tables statements."
  type        = list(string)
  default     = []
}

variable "preview_iceberg_namespace_pattern" {
  description = "Namespace pattern (s3tables:namespace condition) scoping which tables the preview role may drop during teardown — must match your preview names (e.g. pr*) and never prod namespaces"
  type        = string
  default     = "pr*"
}

variable "preview_resource_tag_key" {
  description = "Tag key gating the preview role's KMS key mutations and which keys preview workloads may use (aws/s3-bucket tags a preview's key with the preview stack's tags)"
  type        = string
  default     = "Environment"
}

variable "preview_resource_tag_value" {
  description = "Tag value gating the preview role's KMS key mutations and which keys preview workloads may use"
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
