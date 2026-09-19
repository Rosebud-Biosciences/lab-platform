output "issuer_url" {
  description = "The OIDC issuer URL relying parties are configured with (modules/workloads auth.issuer_url)"
  value       = var.issuer_url
}

output "namespace" {
  description = "Dex's namespace: where environments register OAuth2Client CRs (modules/workloads auth.dex_namespace)"
  value       = local.namespace
}

output "service_name" {
  description = "Dex's Service name"
  value       = local.service_name
}

output "in_cluster_url" {
  description = "In-cluster base URL of Dex (no path); equals the issuer's origin on kind"
  value       = local.in_cluster_url
}

output "client_crd" {
  description = "apiVersion/kind of the custom resource a dynamically registered client is (Dex's kubernetes storage)"
  value       = { api_version = "dex.coreos.com/v1", kind = "OAuth2Client" }
}
