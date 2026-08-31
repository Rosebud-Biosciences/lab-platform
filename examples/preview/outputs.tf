output "preview_name" {
  description = "This preview's stamp"
  value       = var.preview_name
}

output "ephemeral_bucket" {
  description = "Ephemeral processed-data bucket for this preview"
  value       = module.storage.bucket_name
}

output "neon_branches" {
  description = "Names of the copy-on-write Neon branches created for this preview"
  value       = module.neon.branch_names
}

output "webapp_private_url" {
  description = "Private (tailnet) URL for the preview webapp"
  value       = module.workloads.webapp_private_url
}

output "dagster_private_url" {
  description = "Private (tailnet) URL for the preview Dagit"
  value       = module.workloads.dagster_private_url
}

output "mlflow_private_url" {
  description = "Private (tailnet) URL for the preview MLflow"
  value       = module.workloads.mlflow_private_url
}
