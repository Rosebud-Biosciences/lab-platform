variable "name" {
  description = "IAM policy name (e.g. pr123-data-access); one policy per preview keeps attachments and teardown simple"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,128}$", var.name))
    error_message = "name must be a valid IAM policy name (<= 128 chars of [A-Za-z0-9+=,.@_-])."
  }
}

variable "bucket_arn" {
  description = "ARN of the production data bucket holding the store prefixes. Required when prefixes is non-empty."
  type        = string
  default     = ""

  validation {
    condition     = var.bucket_arn == "" || can(regex("^arn:aws[a-z-]*:s3:::[^/]+$", var.bucket_arn))
    error_message = "bucket_arn must be a bucket ARN (arn:aws:s3:::name), not an object or prefix ARN."
  }
}

variable "kms_key_arn" {
  description = "The customer-managed KMS key encrypting bucket_arn (aws/s3-bucket creates one), if any: objects in an SSE-KMS bucket cannot be read or written without kms:Decrypt / kms:GenerateDataKey on it. Empty for SSE-S3."
  type        = string
  default     = ""

  validation {
    condition     = var.kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[^:]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>)."
  }
}

variable "prefixes" {
  description = <<-EOT
    Key prefixes inside bucket_arn the pods may read and write (no delete), e.g.
    ["tether/greetings.icechunk/", "tether/greetings.lance/"] -- the roots of the
    Icechunk / Lance / Delta stores whose branches a preview writes to. A prefix
    without a trailing slash is treated as one.
  EOT
  type        = list(string)
  default     = []
}

variable "table_arns" {
  description = <<-EOT
    S3 Tables table ARNs (arn:aws:s3tables:...:bucket/<name>/table/<uuid>) the
    pods may read and commit metadata to -- required to write an Iceberg branch,
    and NOT scopable to that branch: IAM sees the table, not the ref. Grant it
    only to code you trust with the table's main branch.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.table_arns : can(regex("^arn:aws[a-z-]*:s3tables:[^:]*:[0-9]{12}:bucket/[^/]+/table/[^/]+$", a))])
    error_message = "every table_arns entry must be a full S3 Tables table ARN (.../bucket/<name>/table/<id>)."
  }
}

variable "working_branch_prefix" {
  description = <<-EOT
    Also let the holder delete the Lance working branches inside the prefixes
    whose name starts with this: each one's `_refs/branches/<name>.json` and
    `tree/<name>/`, nothing else. tether names working branches
    `tether.ws.<dataset>.<bookmark>`, so "tether.ws." reaches no main, pinned or
    other ref. For the CI role that retires previews; leave empty (no delete)
    for pods.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^([A-Za-z0-9_-]+[.])*$", var.working_branch_prefix))
    error_message = "working_branch_prefix must be empty or dot-terminated name segments (e.g. \"tether.ws.\"): no wildcards, and never so short it could match main."
  }
}

variable "allow_delete" {
  description = "Let the holder delete anything under the prefixes (the stores a PR created at their real locations). Only for a role that default-branch runs alone can assume (aws/bootstrap's teardown role); never for a role a pull_request run or a pod holds."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the IAM policy"
  type        = map(string)
  default     = {}
}

variable "iam_path" {
  description = "IAM path of the policy; a preview's goes under aws/bootstrap's preview_iam_path"
  type        = string
  default     = "/"

  validation {
    condition     = can(regex("^/([A-Za-z0-9_+=,.@-]+/)*$", var.iam_path))
    error_message = "iam_path starts and ends with /, e.g. / or /preview/."
  }
}
