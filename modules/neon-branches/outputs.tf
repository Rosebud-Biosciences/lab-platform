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
  description = "Name of the ephemeral Neon branch serving each source, keyed by source name (sources sharing a parent share a branch)"
  value       = { for k in keys(local.sources) : k => neon_branch.this[local.source_group[k]].name }
}

output "branches" {
  description = "The ephemeral branches actually created, one per distinct (project, parent branch): {project_id, branch_id, name, sources}"
  value = {
    for g, spec in local.groups : g => {
      project_id = spec.project_id
      branch_id  = neon_branch.this[g].id
      name       = neon_branch.this[g].name
      sources    = spec.sources
    }
  }
}
