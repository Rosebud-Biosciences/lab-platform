output "aws_s3_bucket" {
  description = "The generated bucket (name + ARN)"
  value = {
    bucket = aws_s3_bucket.this.bucket
    arn    = aws_s3_bucket.this.arn
  }
}

output "aws_kms_key_arn" {
  description = "The ARN of the KMS key encrypting the bucket"
  value       = local.aws_kms_key_arn
}

output "aws_iam_policies" {
  description = "The ARNs of the generated S3 bucket access policies"
  value = {
    put_arn    = aws_iam_policy.put.arn
    get_arn    = aws_iam_policy.get.arn
    putget_arn = aws_iam_policy.putget.arn
  }
}
