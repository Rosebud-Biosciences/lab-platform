output "data_bucket" {
  description = "The S3 bucket the kind pods read and write"
  value       = module.data_bucket.aws_s3_bucket.bucket
}

output "issuer_url" {
  description = "The hosted OIDC issuer the kind API server must be started with (null in static-key mode)"
  value       = local.federated ? module.oidc[0].issuer_url : null
}

output "role_arns" {
  description = "Per-service IAM roles the pods assume via web identity (null in static-key mode)"
  value       = local.federated ? module.data[0].role_arns : null
}

output "workload_identity" {
  description = "The identity contract as handed to modules/workloads"
  value       = local.workload_identity
}

output "service_accounts" {
  description = "The subjects the roles trust"
  value       = module.workloads.service_accounts
}

output "iceberg_namespace" {
  description = "Ephemeral Iceberg namespace (null when Iceberg is off)"
  value       = local.iceberg_enabled ? module.iceberg[0].namespace : null
}

output "namespaces" {
  description = "Where everything landed"
  value = {
    webapp  = module.workloads.webapp_namespace
    dagster = module.workloads.dagster_namespace
    ray     = module.workloads.ray_namespace
    mlflow  = module.workloads.mlflow_namespace
  }
}
