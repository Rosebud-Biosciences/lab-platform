locals {
  token_file = "${var.projected_token_mount_path}/token"

  webhook_identity = {
    for svc, role in module.role : svc => {
      service_account_annotations = { "eks.amazonaws.com/role-arn" = role.arn }
      env                         = { AWS_REGION = var.region }
      projected_token             = null
    }
  }

  projected_identity = {
    for svc, role in module.role : svc => {
      service_account_annotations = {}
      env = {
        AWS_REGION                  = var.region
        AWS_ROLE_ARN                = role.arn
        AWS_WEB_IDENTITY_TOKEN_FILE = local.token_file
      }
      projected_token = {
        audience           = "sts.amazonaws.com"
        mount_path         = var.projected_token_mount_path
        file_name          = "token"
        expiration_seconds = 3600
      }
    }
  }
}

output "workload_identity" {
  description = "The workload_identity input for modules/workloads: one entry per enabled service, shaped for the chosen binding"
  value       = var.binding == "webhook" ? local.webhook_identity : local.projected_identity
}

output "workload_identity_secret_env" {
  description = "The workload_identity_secret_env input for modules/workloads. Roles need no static credentials, so this is empty; provided for symmetric wiring."
  value       = {}
}

output "role_arns" {
  description = "Per-service IAM role ARNs"
  value       = { for svc, role in module.role : svc => role.arn }
}

output "service_accounts" {
  description = "The <namespace>/<serviceaccount> subjects each role trusts (must equal modules/workloads' service_accounts output for the same inputs)"
  value       = { for svc in keys(local.roles) : svc => local.subjects[svc] }
}

output "mlflow_artifact_root" {
  description = "The mlflow_artifact_root input for modules/workloads (s3://bucket[/prefix]); empty when MLflow is off"
  value       = var.enable_mlflow ? (var.mlflow_artifact_prefix != "" ? "s3://${var.mlflow_artifact_bucket}/${var.mlflow_artifact_prefix}" : "s3://${var.mlflow_artifact_bucket}") : ""
}
