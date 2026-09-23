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

output "preview_iam_path" {
  description = "IAM path the preview stack must create its roles and policies under (the modules' iam_path)"
  value       = var.preview_iam_path
}

output "preview_permissions_boundary_arn" {
  description = "Permissions boundary every preview role must carry (aws/data-adapter's permissions_boundary_arn); null when the preview role is disabled"
  value       = var.enable_preview_deployer_role ? aws_iam_policy.preview_boundary[0].arn : null
}

output "operator_admin_role_arn" {
  description = "ARN of the MFA-gated operator role (null when disabled). Feed it to eks-platform's access_entries so the role can reach the cluster."
  value       = var.enable_operator_admin_role ? aws_iam_role.operator_admin[0].arn : null
}

output "operator_guardrails_policy_arn" {
  description = "ARN of the operator guardrail Deny policy (null when disabled). Already attached to the role; attach it to the static identities in operator_principal_arns too."
  value       = var.enable_operator_admin_role ? aws_iam_policy.operator_guardrails[0].arn : null
}
