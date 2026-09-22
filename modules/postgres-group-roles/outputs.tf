output "roles" {
  description = "Group path => role name"
  value       = local.roles
}

output "credentials" {
  description = "Group path => { username, password, url }, e.g. for a JupyterHub group profile's secret_env (DATABASE_URL)"
  sensitive   = true
  value = {
    for g, role in local.roles : g => {
      username = role
      password = random_password.role[g].result
      url      = "postgresql://${role}:${random_password.role[g].result}@${var.connection.host}:${var.connection.port}/${var.connection.database}?sslmode=${var.connection.sslmode}"
    }
  }
}
