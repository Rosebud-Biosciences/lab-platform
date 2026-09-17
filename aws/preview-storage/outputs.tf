output "bucket_name" {
  description = "Name of the ephemeral processed-data bucket"
  value       = module.processeddata.aws_s3_bucket.bucket
}

output "bucket_arn" {
  description = "ARN of the ephemeral processed-data bucket"
  value       = module.processeddata.aws_s3_bucket.arn
}

output "bucket_uri" {
  description = "s3:// base URI for the ephemeral bucket (e.g. to set a per-preview output base)"
  value       = "s3://${module.processeddata.aws_s3_bucket.bucket}/"
}

output "putget_policy_arn" {
  description = "IAM policy ARN granting read/write on the ephemeral bucket (pipeline writers)"
  value       = module.processeddata.aws_iam_policies.putget_arn
}

output "get_policy_arn" {
  description = "IAM policy ARN granting read-only on the ephemeral bucket (webapp/readers)"
  value       = module.processeddata.aws_iam_policies.get_arn
}

output "kms_key_arn" {
  description = "ARN of the bucket's KMS key"
  value       = module.processeddata.aws_kms_key_arn
}
