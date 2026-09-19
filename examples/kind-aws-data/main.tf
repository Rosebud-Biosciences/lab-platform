# ------------------------------------------------------------------------------
# KIND + AWS DATA: local compute, cloud data
#
# Data is harder to move than compute, so this is the cell of the matrix that
# earns its keep: the same modules/workloads that runs on EKS, running on a kind
# cluster (a laptop, a CI runner, an on-prem GPU box), reading and writing the
# real S3 bucket / S3 Tables namespace -- with a per-service IAM role and no
# static keys. (Neon branches slot in the same way; the neon provider insists
# on a key at plan time, so examples/preview keeps that wiring.) Three modules
# make the bridge:
#
#   aws/oidc-provider   hosts the kind cluster's OIDC discovery doc + JWKS on
#                       S3 and registers it with IAM (kind's API server is not
#                       reachable from AWS, so the issuer has to live somewhere
#                       AWS can fetch it -- exactly what EKS does internally)
#   aws/data-adapter    per-service roles trusting that issuer, emitted with
#                       binding = "projected": pods mount a projected token and
#                       the SDK reads AWS_ROLE_ARN / AWS_WEB_IDENTITY_TOKEN_FILE
#   modules/workloads   mounts the token; nothing else changes
#
# Flow (scripts/up.sh): create kind with --service-account-issuer set to the
# future bucket URL -> export the JWKS -> tofu apply -> scripts/verify.sh runs
# `aws sts get-caller-identity` from a pod with the Dagster ServiceAccount.
#
# Costs: one S3 bucket, two tiny public objects, IAM roles (free), and S3
# egress for whatever you read from the laptop.
# ------------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  federated = var.oidc_bucket_name != ""

  data_bucket_name = var.data_bucket_name != "" ? var.data_bucket_name : "lab-kind-data-${data.aws_caller_identity.current.account_id}"
  iceberg_enabled  = var.iceberg_table_bucket_arn != ""

  services = ["webapp", "dagster", "ray", "argo", "mlflow"]

  postgres_url = "postgresql://${var.postgres_user}:${var.postgres_password}@${var.postgres_host}:5432/app"
}

# ------------------------------------------------------------------------------
# The data (AWS)
# ------------------------------------------------------------------------------

# Disposable for an example; a real deployment keeps prevent_destroy on.
module "data_bucket" {
  source = "../../aws/s3-bucket"

  name            = local.data_bucket_name
  prevent_destroy = false
  force_destroy   = true
  tags            = var.tags
}

module "iceberg" {
  count  = local.iceberg_enabled ? 1 : 0
  source = "../../aws/iceberg-branches"

  name_prefix      = "${var.cluster_name}${var.name_prefix != "" ? "-${trimsuffix(var.name_prefix, "-")}" : ""}"
  table_bucket_arn = var.iceberg_table_bucket_arn
  tags             = var.tags
}

# ------------------------------------------------------------------------------
# The identity bridge
# ------------------------------------------------------------------------------

module "oidc" {
  count  = local.federated ? 1 : 0
  source = "../../aws/oidc-provider"

  host_discovery = {
    bucket_name = var.oidc_bucket_name
    prefix      = var.cluster_name
    jwks_json   = var.jwks_json
  }
  tags = var.tags
}

locals {
  pipeline_policies = merge(
    { data = module.data_bucket.aws_iam_policies.putget_arn },
    local.iceberg_enabled ? { iceberg_rw = module.iceberg[0].readwrite_policy_arn } : {},
  )
}

module "data" {
  count  = local.federated ? 1 : 0
  source = "../../aws/data-adapter"

  cluster_name      = "kind-${var.cluster_name}"
  name_prefix       = var.name_prefix
  oidc_provider_arn = module.oidc[0].arn
  binding           = "projected"
  region            = var.region

  enable_webapp         = true
  enable_ray            = true
  enable_dagster        = true
  enable_argo_workflows = true
  enable_mlflow         = true

  webapp_policy_arns          = { data = module.data_bucket.aws_iam_policies.get_arn }
  dagster_policy_arns         = local.pipeline_policies
  ray_policy_arns             = local.pipeline_policies
  mlflow_artifact_bucket      = module.data_bucket.aws_s3_bucket.bucket
  mlflow_artifact_bucket_arn  = module.data_bucket.aws_s3_bucket.arn
  mlflow_artifact_prefix      = "mlflow"
  mlflow_artifact_kms_key_arn = module.data_bucket.aws_kms_key_arn
  # Pods pull public images here; no ECR.
  enable_ecr_pull = false

  tags = var.tags
}

# Fallback identity: static keys of an IAM user you attached the bucket's
# putget policy to. Same contract shape, third mechanism.
locals {
  static_identity = {
    for svc in local.services : svc => { env = { AWS_REGION = var.region } }
  }
  static_secret_env = {
    for svc in local.services : svc => {
      AWS_ACCESS_KEY_ID     = var.static_aws_access_key_id
      AWS_SECRET_ACCESS_KEY = var.static_aws_secret_access_key
    }
  }

  # merge() rather than a single conditional: the two identity shapes differ
  # (the adapter's carries a projected_token), and a conditional needs both
  # branches to share a type; `cond ? map : {}` always does.
  workload_identity = merge(
    local.federated ? module.data[0].workload_identity : {},
    local.federated ? {} : local.static_identity,
  )
  workload_identity_secret_env = local.federated ? {} : local.static_secret_env
  mlflow_artifact_root         = local.federated ? module.data[0].mlflow_artifact_root : "s3://${module.data_bucket.aws_s3_bucket.bucket}/mlflow"
}

# ------------------------------------------------------------------------------
# The compute (kind) -- identical module call to the EKS examples
# ------------------------------------------------------------------------------

module "workloads" {
  source = "../../modules/workloads"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  environment = "local"
  name_prefix = var.name_prefix

  workload_identity            = local.workload_identity
  workload_identity_secret_env = local.workload_identity_secret_env

  enable_webapp         = true
  webapp_image          = var.webapp_image
  webapp_container_port = var.webapp_container_port
  webapp_memory_request = "64Mi"
  webapp_memory_limit   = "256Mi"
  database_url          = local.postgres_url

  enable_ray              = true
  enable_ray_cluster      = true
  ray_head_resources      = { requests = { cpu = "500m", memory = "1Gi" }, limits = { cpu = "1", memory = "2Gi" } }
  ray_worker_resources    = { requests = { cpu = "250m", memory = "512Mi" }, limits = { cpu = "1", memory = "1Gi" } }
  ray_worker_max_replicas = 1

  enable_dagster      = true
  dagster_db_host     = var.postgres_host
  dagster_db_name     = "dagster"
  dagster_db_user     = var.postgres_user
  dagster_db_password = var.postgres_password
  # Where pipeline code finds its data: the real bucket, plus the Iceberg
  # namespace when one was carved out.
  dagster_user_code_env = merge(
    { DATA_ROOT = "s3://${module.data_bucket.aws_s3_bucket.bucket}/data" },
    local.iceberg_enabled ? { ICEBERG_NAMESPACE = module.iceberg[0].namespace, ICEBERG_TABLE_BUCKET_ARN = var.iceberg_table_bucket_arn } : {},
  )

  enable_argo_workflows        = true
  enable_argo_workflow_archive = true
  argo_db_host                 = var.postgres_host
  argo_db_name                 = "argo"
  argo_db_user                 = var.postgres_user
  argo_db_password             = var.postgres_password
  argo_db_ssl_mode             = "disable"

  enable_mlflow        = true
  mlflow_artifact_root = local.mlflow_artifact_root
  mlflow_db_host       = var.postgres_host
  mlflow_db_name       = "mlflow"
  mlflow_db_user       = var.postgres_user
  mlflow_db_password   = var.postgres_password

  enable_private_ingress = false
  # verify.sh's probe namespace stands in for the ingress controller.
  network_policies = { ingress_namespaces = ["verify"] }
}
