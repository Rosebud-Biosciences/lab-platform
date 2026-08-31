output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.platform.cluster_name
}

output "mlflow_artifact_bucket" {
  description = "S3 bucket holding MLflow artifacts"
  value       = module.artifacts.aws_s3_bucket.bucket
}

output "webapp_public_url" {
  description = "Public HTTPS URL for the webapp"
  value       = module.workloads.webapp_public_url
}

output "webapp_private_url" {
  description = "Private (tailnet) URL for the webapp"
  value       = module.workloads.webapp_private_url
}

output "dagster_private_url" {
  description = "Private (tailnet) URL for Dagit"
  value       = module.workloads.dagster_private_url
}

output "mlflow_private_url" {
  description = "Private (tailnet) URL for MLflow"
  value       = module.workloads.mlflow_private_url
}

output "ray_dashboard_private_url" {
  description = "Private (tailnet) URL for the Ray dashboard"
  value       = module.workloads.ray_dashboard_private_url
}
