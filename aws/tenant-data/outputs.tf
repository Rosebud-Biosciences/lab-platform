output "role_arn" {
  description = "The tenant's IAM role"
  value       = aws_iam_role.tenant.arn
}

output "service_account_annotations" {
  description = "Annotations for the tenant's ServiceAccounts (modules/tenancy tenant_identity)"
  value       = { "eks.amazonaws.com/role-arn" = aws_iam_role.tenant.arn }
}

output "storage_url" {
  description = "The tenant's slice of object storage (s3://bucket/[tenants/<tenant>/])"
  value       = local.storage_url
}

output "bucket_arn" {
  description = "ARN of the bucket holding the tenant's data"
  value       = local.bucket_arn
}

output "database" {
  description = "The tenant's own database (database = \"own_database\"): name, username, password, url"
  sensitive   = true
  value = var.database == "own_database" ? {
    name     = postgresql_database.tenant[0].name
    username = postgresql_role.owner[0].name
    password = random_password.database[0].result
    url      = "postgresql://${postgresql_role.owner[0].name}:${random_password.database[0].result}@${var.database_connection.host}:${var.database_connection.port}/${postgresql_database.tenant[0].name}?sslmode=${var.database_connection.sslmode}"
  } : null
}
