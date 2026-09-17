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
