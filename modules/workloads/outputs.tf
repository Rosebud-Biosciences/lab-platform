locals {
  private_dns_suffix = var.private_ingress_dns_suffix != "" ? var.private_ingress_dns_suffix : "<your-suffix>"
}

output "webapp_namespace" {
  description = "Webapp namespace (if enabled)"
  value       = var.enable_webapp ? kubernetes_namespace_v1.webapp[0].metadata[0].name : null
}

output "dagster_namespace" {
  description = "Dagster namespace (if enabled)"
  value       = local.enable_dagster ? kubernetes_namespace_v1.dagster[0].metadata[0].name : null
}

output "mlflow_namespace" {
  description = "MLflow namespace (if enabled)"
  value       = var.enable_mlflow ? kubernetes_namespace_v1.mlflow[0].metadata[0].name : null
}

output "ray_namespace" {
  description = "Ray namespace (if enabled)"
  value       = var.enable_ray ? kubernetes_namespace_v1.ray[0].metadata[0].name : null
}

output "jupyterhub_namespace" {
  description = "JupyterHub namespace (if enabled)"
  value       = var.enable_jupyterhub ? kubernetes_namespace_v1.jupyterhub[0].metadata[0].name : null
}

output "dagster_private_url" {
  description = "Private URL for Dagit (if the private ingress + DNS suffix are set)"
  value       = var.enable_private_ingress && local.enable_dagster ? "https://${local.private_dagster_host}.${local.private_dns_suffix}" : null
}

output "mlflow_private_url" {
  description = "Private URL for the MLflow UI"
  value       = var.enable_private_ingress && var.enable_mlflow ? "https://${local.private_mlflow_host}.${local.private_dns_suffix}" : null
}

output "webapp_private_url" {
  description = "Private URL for the webapp"
  value       = var.enable_private_ingress && var.enable_webapp ? "https://${local.private_webapp_host}.${local.private_dns_suffix}" : null
}

output "ray_dashboard_private_url" {
  description = "Private URL for the Ray dashboard (502s while no Ray cluster is running)"
  value       = var.enable_private_ingress && var.enable_ray ? "https://${local.private_ray_host}.${local.private_dns_suffix}" : null
}

output "webapp_public_url" {
  description = "Public HTTPS URL for the webapp (null unless the public ingress is enabled)"
  value       = local.webapp_public_enabled ? "https://${var.webapp_public_host}" : null
}
