# ------------------------------------------------------------------------------
# Per-service IAM roles, trusting <namespace>/<serviceaccount> subjects that
# mirror modules/workloads' identity contract (README "Identity contract").
#
# The trust policy is plain OIDC federation -- issuer = the provider's URL,
# sub = system:serviceaccount:<ns>:<sa>, aud = sts.amazonaws.com -- so the same
# roles work whether the token is injected by EKS's webhook or mounted by
# workloads on a kind/GKE/AKS/on-prem cluster whose issuer aws/oidc-provider
# registered. Only the binding output differs.
# ------------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  prefix          = var.name_prefix
  iam_desc_suffix = local.prefix != "" ? " (${local.prefix})" : ""

  # The identity contract: must match modules/workloads locals exactly.
  subjects = {
    webapp     = { namespace = "${local.prefix}${var.webapp_app_name}", name = var.webapp_app_name }
    dagster    = { namespace = "${local.prefix}dagster", name = "dagster" }
    ray        = { namespace = "${local.prefix}ray", name = "ray-s3-sa" }
    argo       = { namespace = "${local.prefix}argo", name = "argo-workflow" }
    mlflow     = { namespace = "${local.prefix}mlflow", name = "mlflow" }
    jupyterhub = { namespace = "${local.prefix}jupyterhub", name = "jupyterhub-single-user" }
  }

  enabled = {
    webapp     = var.enable_webapp
    dagster    = var.enable_dagster
    ray        = var.enable_ray
    argo       = var.enable_argo_workflows
    mlflow     = var.enable_mlflow
    jupyterhub = var.enable_jupyterhub
  }

  ecr_read = var.enable_ecr_pull && (var.enable_ray || var.enable_argo_workflows || var.enable_dagster) ? { ecr_read = aws_iam_policy.ecr_read[0].arn } : {}

  policies = {
    webapp  = var.webapp_policy_arns
    dagster = merge(local.ecr_read, var.dagster_policy_arns)
    ray     = merge(local.ecr_read, var.ray_policy_arns)
    argo    = merge(local.ecr_read, var.ray_policy_arns)
    mlflow  = var.enable_mlflow ? { s3 = aws_iam_policy.mlflow_s3[0].arn } : {}
    jupyterhub = merge(
      var.jupyterhub_s3_read_only ? { s3_read = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonS3ReadOnlyAccess" } : {},
      var.jupyterhub_policy_arns,
    )
  }

  # Short role-name segment per service (kept from the pre-adapter module so
  # existing roles can be state-moved rather than recreated).
  role_segment = {
    webapp     = "${var.webapp_app_name}-sa"
    dagster    = "dagster-sa"
    ray        = "ray-cluster-sa"
    argo       = "argo-workflow-sa"
    mlflow     = "mlflow-sa"
    jupyterhub = "jhub-single-user-sa"
  }

  roles = { for svc, on in local.enabled : svc => svc if on }
}

module "role" {
  for_each = local.roles
  source   = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version  = "~> 6.8"

  name            = "${var.cluster_name}-${local.prefix}${local.role_segment[each.key]}"
  use_name_prefix = false
  description     = "modules/workloads ${each.key} service account${local.iam_desc_suffix}"

  policies = local.policies[each.key]

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${local.subjects[each.key].namespace}:${local.subjects[each.key].name}"]
    }
  }

  tags = var.tags
}

# GetAuthorizationToken accepts only "*"; the pull actions take repository
# ARNs, so they are scoped to this account's repositories in this region.
resource "aws_iam_policy" "ecr_read" {
  count       = var.enable_ecr_pull && (var.enable_ray || var.enable_argo_workflows || var.enable_dagster) ? 1 : 0
  name        = "${var.cluster_name}-${local.prefix}ecr-read"
  description = "ECR read policy for Ray, Argo Workflows and Dagster${local.iam_desc_suffix}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Login"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "PullFromAccountRepositories"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_policy" "mlflow_s3" {
  count       = var.enable_mlflow ? 1 : 0
  name        = "${var.cluster_name}-${local.prefix}mlflow-s3"
  description = "Access to the MLflow artifact bucket for the tracking server${local.iam_desc_suffix}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
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
      ],
      var.mlflow_artifact_kms_key_arn != "" ? [{
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.mlflow_artifact_kms_key_arn
      }] : []
    )
  })

  tags = var.tags
}
