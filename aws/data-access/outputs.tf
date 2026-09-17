output "policy_arn" {
  description = "ARN of the data-access policy; attach it to the preview's Dagster / Ray / webapp service accounts (the workloads module's *_bucket_policies maps) and to the CI identity that forks the data"
  value       = aws_iam_policy.this.arn
}

output "policy_name" {
  description = "Name of the data-access policy"
  value       = aws_iam_policy.this.name
}

output "prefixes" {
  description = "The normalised (trailing-slash) prefixes the policy grants read/write on"
  value       = local.prefixes
}
