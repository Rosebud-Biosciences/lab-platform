# ------------------------------------------------------------------------------
# WORKLOADS MODULE - ARGO WORKFLOWS (per environment, namespaced by name_prefix)
#
# Argo follows Dagster and MLflow: its own namespace, a namespace-scoped
# controller + server (singleNamespace), an optional workflow archive on the
# environment's Postgres, and its own private UI. The cluster-scoped CRDs are
# a cluster prerequisite (aws/eks-platform enable_argo_workflows), installed
# once; this release installs none and creates no other cluster-scoped object
# beyond its name-prefixed ClusterRole.
#
# Workflows run as the `argo-workflow` ServiceAccount (identity contract key
# "argo"), which the module-owned ClusterRole lets create RayJobs/RayClusters
# in this environment's Ray namespace -- the ephemeral-Ray pattern in
# docs/ephemeral-ray.md. Static credentials for workflow pods are in the
# argo-identity-env Secret; templates envFrom it (and add the projected token
# volume when federating).
# ------------------------------------------------------------------------------

locals {
  argo_release        = "${local.prefix}argo"
  argo_server_service = "${local.argo_release}-server" # fullnameOverride = release
  argo_db_secret      = "argo-postgres-credentials"

  argo_archive = var.enable_argo_workflows && var.enable_argo_workflow_archive
}

resource "kubernetes_namespace_v1" "argo" {
  count = var.enable_argo_workflows ? 1 : 0

  metadata {
    name = local.argo_namespace
  }
}

resource "kubernetes_service_account_v1" "argo_workflow" {
  count = var.enable_argo_workflows ? 1 : 0

  metadata {
    name        = local.argo_service_account_name
    namespace   = kubernetes_namespace_v1.argo[0].metadata[0].name
    annotations = local.identity.argo.service_account_annotations
  }
}

# What a workflow may do to the cluster: manage RayJobs/RayClusters (in this
# environment's Ray namespace -- cross-namespace, hence a ClusterRole) and the
# pods/services around them. Name-prefixed so environments never collide.
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
  count = var.enable_argo_workflows ? 1 : 0

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
    namespace = kubernetes_namespace_v1.argo[0].metadata[0].name
  }
}

# Identity contract: static credentials for workflow pods (templates envFrom
# it). Exists even when empty so templates can reference it unconditionally.
resource "kubernetes_secret_v1" "argo_identity_env" {
  count = var.enable_argo_workflows ? 1 : 0

  metadata {
    name      = local.identity_secret_name.argo
    namespace = kubernetes_namespace_v1.argo[0].metadata[0].name
  }

  data = local.identity_secret_env.argo
}

# Workflow archive credentials (the chart reads them from a Secret in its
# namespace).
resource "kubernetes_secret_v1" "argo_db" {
  count = local.argo_archive ? 1 : 0

  metadata {
    name      = local.argo_db_secret
    namespace = kubernetes_namespace_v1.argo[0].metadata[0].name
  }

  data = {
    username = var.argo_db_user
    password = var.argo_db_password
  }
}

resource "helm_release" "argo_workflows" {
  count = var.enable_argo_workflows ? 1 : 0

  namespace  = kubernetes_namespace_v1.argo[0].metadata[0].name
  name       = local.argo_release
  repository = var.argo_workflows_repository
  chart      = "argo-workflows"
  version    = var.argo_workflows_chart_version
  timeout    = 600

  values = [templatefile("${local.helm_defaults}/argo/values.yaml", {
    fullname      = local.argo_release
    workflow_sa   = local.argo_service_account_name
    archive       = local.argo_archive
    db_host       = var.argo_db_host
    db_port       = var.argo_db_port
    db_name       = var.argo_db_name
    db_ssl_mode   = var.argo_db_ssl_mode
    db_secret     = local.argo_db_secret
    node_selector = jsonencode(local.scheduling.argo.node_selector)
    tolerations   = jsonencode(local.scheduling.argo.tolerations)
  })]

  depends_on = [
    kubernetes_service_account_v1.argo_workflow,
    kubernetes_cluster_role_binding_v1.argo_workflow,
    kubernetes_secret_v1.argo_identity_env,
    kubernetes_secret_v1.argo_db,
  ]
}
