output "base_url" {
  description = "Keycloak's public base URL (the hostname variable); a realm's issuer is <base_url>/realms/<realm>"
  value       = var.hostname
}

output "internal_url" {
  description = "In-cluster base URL of Keycloak's HTTP Service"
  value       = local.internal_url
}

output "namespace" {
  description = "Keycloak's namespace"
  value       = local.namespace
}

output "service_name" {
  description = "Keycloak's HTTP Service"
  value       = local.service_name
}

output "admin_client_id" {
  description = "The master-realm admin service account (client credentials) modules/keycloak-realm's provider authenticates with"
  value       = var.bootstrap_admin_client_id
}

output "admin_client_secret" {
  description = "Its secret"
  value       = random_password.bootstrap_admin.result
  sensitive   = true
}

output "release" {
  description = "The Helm release, for depends_on in callers configuring the realm"
  value       = helm_release.keycloak.id
}
