output "state_bucket_name" {
  description = "Name of the Terraform state bucket"
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state bucket"
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "Name of the DynamoDB state lock table"
  value       = aws_dynamodb_table.locks.name
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider (created or reused)"
  value       = local.oidc_provider_arn
}

output "ci_deployer_role_arn" {
  description = "ARN of the CI deployer role (null when disabled)"
  value       = var.enable_ci_deployer_role ? aws_iam_role.ci_deployer[0].arn : null
}

output "preview_deployer_role_arn" {
  description = "ARN of the preview deployer role (null when disabled)"
  value       = var.enable_preview_deployer_role ? aws_iam_role.preview_deployer[0].arn : null
}
