variable "name" {
  description = "The name of the bucket (must be globally unique)"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "prevent_destroy" {
  description = "Attach a bucket policy that denies s3:DeleteBucket and a KMS policy that denies key deletion"
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Allow `tofu destroy` to delete the bucket even when it still contains objects (for ephemeral/preview buckets)"
  type        = bool
  default     = false
}

variable "versioning" {
  description = "Whether to enable object versioning"
  type        = bool
  default     = true
}

variable "aws_kms_key_arn" {
  description = "Existing KMS key ARN to encrypt with. Empty string generates a dedicated key for this bucket."
  type        = string
  default     = ""
}

variable "deployment_user_arn" {
  description = "Principal ARN granted full control over a generated KMS key (only used when aws_kms_key_arn is empty). Defaults to the account root."
  type        = string
  default     = ""
}

variable "put_users" {
  description = "Existing IAM user names to attach the put policy to"
  type        = list(string)
  default     = []
}

variable "get_users" {
  description = "Existing IAM user names to attach the get policy to"
  type        = list(string)
  default     = []
}

variable "putget_users" {
  description = "Existing IAM user names to attach the putget policy to"
  type        = list(string)
  default     = []
}

variable "transition_days" {
  description = "Days after creation to transition current objects to a cheaper storage class (0 = disabled)"
  type        = number
  default     = 0
}

variable "transition_storage_class" {
  description = "Storage class for transitioned current objects"
  type        = string
  default     = "GLACIER_IR"
}

variable "deep_archive_transition_days" {
  description = "Days after creation to transition current objects to DEEP_ARCHIVE (0 = disabled)"
  type        = number
  default     = 0
}

variable "noncurrent_transition_days" {
  description = "Days after becoming noncurrent to transition old versions to a cheaper storage class (0 = disabled)"
  type        = number
  default     = 0
}

variable "noncurrent_transition_storage_class" {
  description = "Storage class for transitioned noncurrent object versions"
  type        = string
  default     = "GLACIER_IR"
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Days after which incomplete multipart uploads are aborted"
  type        = number
  default     = 7
}

variable "intelligent_tiering_deep_archive_days" {
  description = "Days of no access before Intelligent-Tiering moves objects to the Deep Archive Access tier (0 = disabled, min 180)"
  type        = number
  default     = 0
}

variable "intelligent_tiering_prefix" {
  description = "Prefix filter for the Intelligent-Tiering deep-archive configuration (empty = whole bucket)"
  type        = string
  default     = ""
}

variable "archive_tag_transition" {
  description = "Transition objects tagged archived=true to DEEP_ARCHIVE (explicit per-project archival)"
  type        = bool
  default     = false
}
