# ------------------------------------------------------------------------------
# WORKLOADS MODULE - MLFLOW TRACKING SERVER (namespaced by name_prefix)
# ------------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "mlflow" {
  count = var.enable_mlflow ? 1 : 0

  metadata {
    name = local.mlflow_namespace
  }
}

resource "aws_iam_policy" "mlflow_s3" {
  count       = var.enable_mlflow ? 1 : 0
  name        = "${var.cluster_name}-${local.prefix}mlflow-s3"
  description = "Access to the MLflow artifact bucket for the tracking server${local.iam_desc_suffix}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = var.mlflow_artifact_bucket_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${var.mlflow_artifact_bucket_arn}/*"
      }
    ]
  })
}

module "mlflow_irsa" {
  count   = var.enable_mlflow ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name            = "${var.cluster_name}-${local.prefix}mlflow-sa"
  use_name_prefix = false

  policies = {
    s3 = aws_iam_policy.mlflow_s3[0].arn
  }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${local.mlflow_namespace}:${local.mlflow_service_account_name}"]
    }
  }
}

resource "kubernetes_secret_v1" "mlflow_db" {
  count = var.enable_mlflow ? 1 : 0

  metadata {
    name      = "mlflow-db-credentials"
    namespace = kubernetes_namespace_v1.mlflow[0].metadata[0].name
  }

  data = {
    username = var.mlflow_db_user
    password = var.mlflow_db_password
  }
}

resource "helm_release" "mlflow" {
  count = var.enable_mlflow ? 1 : 0

  namespace  = kubernetes_namespace_v1.mlflow[0].metadata[0].name
  name       = local.mlflow_release
  repository = var.mlflow_repository
  chart      = "mlflow"
  version    = var.mlflow_chart_version
  timeout    = 600

  values = [templatefile("${local.helm_defaults}/mlflow/values.yaml", {
    service_account_name = local.mlflow_service_account_name
    irsa_role_arn        = module.mlflow_irsa[0].arn
    artifact_bucket      = var.mlflow_artifact_bucket
    db_host              = var.mlflow_db_host
    db_name              = var.mlflow_db_name
    db_secret_name       = kubernetes_secret_v1.mlflow_db[0].metadata[0].name
  })]
}
