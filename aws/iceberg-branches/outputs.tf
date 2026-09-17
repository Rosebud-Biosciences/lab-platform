output "namespace" {
  description = "The preview's Iceberg namespace in the shared table bucket"
  value       = aws_s3tables_namespace.preview.namespace
}

output "table_bucket_arn" {
  description = "The shared table bucket the namespace lives in (passthrough)"
  value       = var.table_bucket_arn
}

output "readwrite_policy_arn" {
  description = "IAM policy granting read/write scoped to the preview namespace"
  value       = aws_iam_policy.readwrite.arn
}

output "read_policy_arn" {
  description = "IAM policy granting read-only access to the listed prod namespaces (null when read_namespaces is empty)"
  value       = length(var.read_namespaces) > 0 ? aws_iam_policy.read[0].arn : null
}
