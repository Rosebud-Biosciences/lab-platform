# ------------------------------------------------------------------------------
# WORKLOADS MODULE - RAY & ARGO WORKFLOWS (namespaced by name_prefix)
#
# Deploys the Ray namespace, an IRSA-backed service account (S3 + ECR read), an
# optional persistent Ray cluster (KubeRay ray-cluster chart), and an optional
# Argo Workflows service account + RBAC. The KubeRay operator itself lives in
# the platform module.
# ------------------------------------------------------------------------------

locals {
  ray_dashboard_service = "ray-dashboard"

  ray_dashboard_cluster = var.ray_dashboard_cluster_name != "" ? var.ray_dashboard_cluster_name : "${local.prefix}${var.ray_cluster_release_name}"

  # The two labels KubeRay's head Service selects on, so this matches that
  # cluster's head Pod and nothing else in the namespace.
  ray_head_selector = {
    "ray.io/cluster"   = local.ray_dashboard_cluster
    "ray.io/node-type" = "head"
  }
}

resource "kubernetes_namespace_v1" "ray" {
  count = var.enable_ray ? 1 : 0

  metadata {
    name = local.ray_namespace
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# GetAuthorizationToken accepts only "*"; the pull actions take repository
# ARNs, so they are scoped to this account's repositories in this region.
resource "aws_iam_policy" "ecr_read" {
  count       = var.enable_ray || var.enable_argo_workflows ? 1 : 0
  name        = "${var.cluster_name}-${local.prefix}ecr-read"
  description = "ECR read policy for Ray and Argo Workflows${local.iam_desc_suffix}"

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

module "ray_cluster_irsa" {
  count   = var.enable_ray ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name            = "${var.cluster_name}-${local.prefix}ray-cluster-sa"
  use_name_prefix = false

  policies = merge(
    { ecr_read = aws_iam_policy.ecr_read[0].arn },
    var.ray_storage_bucket_policies
  )

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${kubernetes_namespace_v1.ray[0].metadata[0].name}:ray-s3-sa"]
    }
  }
}

resource "kubernetes_service_account_v1" "ray_cluster_sa" {
  count = var.enable_ray ? 1 : 0

  metadata {
    name        = "ray-s3-sa"
    namespace   = kubernetes_namespace_v1.ray[0].metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" : module.ray_cluster_irsa[0].arn }
  }

  automount_service_account_token = true
}

# Shared analytics env for pipeline compute: MLflow tracking + region.
resource "kubernetes_config_map_v1" "analytics_config" {
  count = var.enable_ray ? 1 : 0

  metadata {
    name      = "analytics-config"
    namespace = kubernetes_namespace_v1.ray[0].metadata[0].name
  }

  data = {
    "AWS_REGION"          = var.region
    "MLFLOW_TRACKING_URI" = local.mlflow_tracking_uri
    "PIPELINE_ENV"        = var.environment
  }
}

resource "kubernetes_secret_v1" "database_url" {
  count = var.enable_ray && var.database_url != "" ? 1 : 0

  metadata {
    name      = "database-url"
    namespace = kubernetes_namespace_v1.ray[0].metadata[0].name
  }

  data = {
    DATABASE_URL = var.database_url
  }
}

# ------------------------------------------------------------------------------
# Argo Workflows service account + RBAC (cluster-scoped RBAC is name-prefixed)
# ------------------------------------------------------------------------------

module "argo_workflow_irsa" {
  count   = var.enable_argo_workflows ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name            = "${var.cluster_name}-${local.prefix}argo-workflow-sa"
  use_name_prefix = false

  policies = merge(
    { ecr_read = aws_iam_policy.ecr_read[0].arn },
    var.ray_storage_bucket_policies
  )

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = var.enable_ray ? ["${kubernetes_namespace_v1.ray[0].metadata[0].name}:argo-workflow"] : []
    }
  }
}

resource "kubernetes_service_account_v1" "argo_workflow" {
  count = var.enable_argo_workflows && var.enable_ray ? 1 : 0

  metadata {
    name      = "argo-workflow"
    namespace = kubernetes_namespace_v1.ray[0].metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" : module.argo_workflow_irsa[0].arn
    }
  }
}

resource "kubernetes_cluster_role_v1" "argo_workflow" {
  count = var.enable_argo_workflows ? 1 : 0

  metadata {
    name = "${local.prefix}argo-workflow-role"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "configmaps", "services"]
    verbs      = ["get", "watch", "patch", "list", "create", "delete"]
  }

  rule {
    api_groups = ["ray.io"]
    # rayjobs is the ephemeral-cluster primitive (shutdownAfterJobFinishes);
    # rayclusters is retained for workflows that manage a cluster's lifecycle by
    # hand. See docs/ephemeral-ray.md.
    resources = ["rayclusters", "rayclusters/status", "rayclusters/finalizers", "rayjobs", "rayjobs/status"]
    verbs     = ["get", "list", "create", "delete", "patch", "watch", "update"]
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflowtaskresults"]
    verbs      = ["create", "patch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "argo_workflow" {
  count = var.enable_argo_workflows && var.enable_ray ? 1 : 0

  metadata {
    name = "${local.prefix}argo-workflow-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.argo_workflow[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.argo_workflow[0].metadata[0].name
    namespace = kubernetes_namespace_v1.ray[0].metadata[0].name
  }
}

# ------------------------------------------------------------------------------
# Persistent Ray cluster (optional)
# ------------------------------------------------------------------------------

resource "helm_release" "ray_cluster" {
  count = var.enable_ray && var.enable_ray_cluster ? 1 : 0

  namespace  = kubernetes_namespace_v1.ray[0].metadata[0].name
  name       = "${local.prefix}${var.ray_cluster_release_name}"
  repository = var.ray_cluster_repository
  chart      = "ray-cluster"
  version    = var.ray_cluster_chart_version
  timeout    = 600

  values = [templatefile("${local.helm_defaults}/ray/values.yaml", {
    image_repo              = var.ray_image_repository
    image_tag               = local.ray_image_tag
    ray_version             = var.ray_version
    ray_single_user_sa_name = kubernetes_service_account_v1.ray_cluster_sa[0].metadata[0].name
    gpu_image_repo          = var.ray_gpu_image_repository
    gpu_image_tag           = local.ray_gpu_image_tag
  })]
}

# ------------------------------------------------------------------------------
# RAY DASHBOARD SERVICE (stable backend for the private Ingress)
#
# A Terraform-owned ClusterIP Service so the private hostname stays put across
# the create/delete cycle of the RayCluster itself; the selector picks up
# whichever head Pod is currently up (502s while none is running).
# ------------------------------------------------------------------------------

resource "kubernetes_service_v1" "ray_dashboard" {
  count = var.enable_ray && var.enable_private_ingress ? 1 : 0

  metadata {
    name      = local.ray_dashboard_service
    namespace = kubernetes_namespace_v1.ray[0].metadata[0].name
  }

  spec {
    selector = local.ray_head_selector

    port {
      name        = "dashboard"
      port        = 80
      target_port = 8265
    }

    type = "ClusterIP"
  }
}
