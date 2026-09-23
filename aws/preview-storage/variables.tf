variable "name_prefix" {
  description = "Unique per-preview prefix (e.g. the PR/preview name). Used to name the ephemeral bucket so it never collides with prod."
  type        = string
}

variable "bucket_base_name" {
  description = "Base name for the ephemeral bucket; the final name is \"<bucket_base_name>-<name_prefix>\""
  type        = string
  default     = "preview-processeddata"
}

variable "tags" {
  description = "Tags applied to the created resources"
  type        = map(string)
  default     = {}
}

variable "iam_path" {
  description = "IAM path of the bucket's access policies: aws/bootstrap's preview_iam_path, which the preview role is confined to"
  type        = string
  default     = "/preview/"

  validation {
    condition     = can(regex("^/([A-Za-z0-9_+=,.@-]+/)*$", var.iam_path))
    error_message = "iam_path starts and ends with /, e.g. / or /preview/."
  }
}
