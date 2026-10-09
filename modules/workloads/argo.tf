# ------------------------------------------------------------------------------
# WORKLOADS MODULE - ARGO WORKFLOWS (per environment, namespaced by name_prefix)
#
# Argo follows Dagster and MLflow: its own namespace, a namespace-scoped
# controller + server (singleNamespace), an optional workflow archive on the
# environment's Postgres, and its own private UI. The cluster-scoped CRDs are
# a cluster prerequisite (aws/eks-platform enable_argo_workflows), installed
# once; this release installs none and creates no cluster-scoped object.
#
# Workflows run as the `argo-workflow` ServiceAccount (identity contract key
# "argo"), which the module's namespaced Roles let run pods in Argo's namespace
# and create RayJobs/RayClusters in this environment's Ray namespace -- the
# ephemeral-Ray pattern in
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
    name = local.namespace_names.argo
    # NetworkPolicies admit client services by this label (netpol.tf).
    labels = merge({ "lab-platform.io/service" = "argo" }, local.tenant_labels)
  }
}

resource "kubernetes_service_account_v1" "argo_workflow" {
  count = var.enable_argo_workflows ? 1 : 0

  metadata {
    name        = local.argo_service_account_name
    namespace   = local.argo_namespace
    annotations = local.identity.argo.service_account_annotations
  }
}

# What a workflow may do, and where: its own pods in Argo's namespace, and
# RayJobs/RayClusters in this environment's Ray namespace. Namespaced Roles, not
# a ClusterRole: the right to create pods (or RayClusters, whose pods may name
# any ServiceAccount of their namespace) anywhere would be the right to run as
# any identity in the cluster -- another environment's, or prod's.
resource "kubernetes_role_v1" "argo_workflow" {
  count = var.enable_argo_workflows ? 1 : 0

  metadata {
    name      = "${local.prefix}argo-workflow-role"
    namespace = local.argo_namespace
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "configmaps", "services"]
    verbs      = ["get", "watch", "patch", "list", "create", "delete"]
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflowtaskresults"]
    verbs      = ["create", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "argo_workflow" {
  count = var.enable_argo_workflows ? 1 : 0

  metadata {
    name      = "${local.prefix}argo-workflow-binding"
    namespace = local.argo_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.argo_workflow[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.argo_workflow[0].metadata[0].name
    namespace = local.argo_namespace
  }
}

resource "kubernetes_role_v1" "argo_workflow_ray" {
  count = var.enable_argo_workflows && var.enable_ray ? 1 : 0

  metadata {
    name      = "${local.prefix}argo-workflow-ray"
    namespace = local.ray_namespace
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
    api_groups = [""]
    resources  = ["pods", "pods/log", "services"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "argo_workflow_ray" {
  count = var.enable_argo_workflows && var.enable_ray ? 1 : 0

  metadata {
    name      = "${local.prefix}argo-workflow-ray"
    namespace = local.ray_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.argo_workflow_ray[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.argo_workflow[0].metadata[0].name
    namespace = local.argo_namespace
  }
}

# Identity contract: static credentials for workflow pods (templates envFrom
# it). Exists even when empty so templates can reference it unconditionally.
resource "kubernetes_secret_v1" "argo_identity_env" {
  count = var.enable_argo_workflows ? 1 : 0

  metadata {
    name      = local.identity_secret_name.argo
    namespace = local.argo_namespace
  }

  data = local.identity_secret_env.argo
}

# Workflow archive credentials (the chart reads them from a Secret in its
# namespace).
resource "kubernetes_secret_v1" "argo_db" {
  count = local.argo_archive ? 1 : 0

  metadata {
    name      = local.argo_db_secret
    namespace = local.argo_namespace
  }

  data = {
    username = var.argo_db_user
    password = var.argo_db_password
  }
}

resource "helm_release" "argo_workflows" {
  count = var.enable_argo_workflows ? 1 : 0

  namespace  = local.argo_namespace
  name       = local.argo_release
  repository = var.argo_workflows_repository
  chart      = "argo-workflows"
  atomic     = true
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
    # auth mode "oidc" (auth.tf): native SSO against the environment's issuer.
    sso              = local.argo_sso
    sso_issuer       = jsonencode(var.auth.issuer_url)
    sso_secret       = local.argo_sso_secret
    sso_redirect_url = jsonencode(try(local.auth_redirect_uris.argo[0], ""))
    sso_scopes       = jsonencode(var.auth.scopes)
    sso_groups_claim = jsonencode(var.auth.groups_claim)
  })]

  depends_on = [
    kubernetes_service_account_v1.argo_workflow,
    kubernetes_role_binding_v1.argo_workflow,
    kubernetes_role_binding_v1.argo_workflow_ray,
    kubernetes_secret_v1.argo_identity_env,
    kubernetes_secret_v1.argo_db,
    kubernetes_secret_v1.argo_sso,
    kubernetes_service_account_v1.argo_sso,
    kubernetes_role_binding_v1.argo_sso,
  ]
}
