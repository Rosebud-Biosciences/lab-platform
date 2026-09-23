variable "table_bucket_arn" {
  description = "ARN of the existing shared S3 Tables (Iceberg) table bucket the preview namespace is created in"
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:s3tables:", var.table_bucket_arn))
    error_message = "table_bucket_arn must be an S3 Tables table-bucket ARN (arn:aws:s3tables:...)."
  }
}

variable "name_prefix" {
  description = "Per-preview identity (e.g. pr123). Becomes the namespace name after sanitising to S3 Tables rules ([a-z0-9_])."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]{0,29}$", var.name_prefix))
    error_message = "name_prefix must be <= 30 lowercase alphanumeric/dash/underscore characters starting with an alphanumeric."
  }
}

variable "read_namespaces" {
  description = "Existing (prod) Iceberg namespaces in the same table bucket this preview may READ. Empty skips the read policy."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to the IAM policies (S3 Tables namespaces do not support tags)"
  type        = map(string)
  default     = {}
}

variable "iam_path" {
  description = "IAM path of the namespace's policies: aws/bootstrap's preview_iam_path, which the preview role is confined to"
  type        = string
  default     = "/preview/"

  validation {
    condition     = can(regex("^/([A-Za-z0-9_+=,.@-]+/)*$", var.iam_path))
    error_message = "iam_path starts and ends with /, e.g. / or /preview/."
  }
}

variable "drop_tables_on_destroy" {
  description = "On destroy, drop the tables in the namespace first (the preview's migrations made them; a namespace is only deleted empty). Needs the AWS CLI v2 where tofu runs. Turning it off on a live namespace destroys the drop step, which drops the tables then."
  type        = bool
  default     = true
}
