variable "region" {
  description = "AWS region of the shared cluster"
  type        = string
  default     = "us-west-2"
}

variable "preview_name" {
  description = "Unique per-PR name (e.g. pr123). Stamps every namespace/release/hostname/bucket so the preview never collides with prod or other previews. Usually derived from the Terraform workspace."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,19}$", var.preview_name))
    error_message = "preview_name must be <= 20 lowercase alphanumeric/dash characters starting with an alphanumeric."
  }
}

# ------------------------------------------------------------------------------
# SHARED CLUSTER (created once by the prod platform stack / examples/complete)
#
# In real use these come from that stack's remote state -- see the commented
# terraform_remote_state block in main.tf. They are plain variables here so the
# example stays self-contained.
# ------------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the existing shared EKS cluster"
  type        = string
}

variable "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN of the shared cluster"
  type        = string
}

variable "vpc_name" {
  description = "VPC name used by Karpenter NodePools for subnet/SG discovery"
  type        = string
}

variable "karpenter_node_iam_role_name" {
  description = "Name of the shared cluster's Karpenter node IAM role"
  type        = string
}

variable "private_ingress_dns_suffix" {
  description = "MagicDNS suffix of the tailnet (e.g. tailXXXX.ts.net), used to build the preview's private URLs"
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# IMAGES UNDER TEST (CI passes the PR's built tags)
# ------------------------------------------------------------------------------

variable "webapp_image" {
  description = "Webapp image (repository:tag) built for this PR"
  type        = string
}

# ------------------------------------------------------------------------------
# NEON (copy-on-write DB branches)
# ------------------------------------------------------------------------------

variable "neon_api_key" {
  description = "Neon API key used to cut the preview's copy-on-write branches"
  type        = string
  default     = ""
  sensitive   = true
}

variable "neon_branch_sources" {
  description = <<-EOT
    Parent Neon branches to clone for this preview, keyed by logical name. Use
    the keys "app", "dagster", and "mlflow" to wire them into the workloads
    below. Typically populated from the prod data-storage stack's remote state.
    Leave empty to skip Neon and supply your own DB connections.
  EOT
  type = map(object({
    project_id       = string
    parent_branch_id = string
    role_name        = string
    db_name          = string
  }))
  default = {}
}

variable "tags" {
  description = "Extra tags (merged with the preview identity tags)"
  type        = map(string)
  default     = {}
}
