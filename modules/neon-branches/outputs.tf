output "connections" {
  description = "Per-source connection details (host, user, password, dbname), keyed by the logical source name"
  value       = local.connections
  sensitive   = true
}

output "postgres_urls" {
  description = "Per-source SQLAlchemy-style Postgres URLs, keyed by the logical source name"
  value       = local.postgres_urls
  sensitive   = true
}

output "branch_names" {
  description = "Names of the ephemeral Neon branches created for this preview"
  value       = { for k, b in neon_branch.this : k => b.name }
}
