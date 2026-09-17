# ------------------------------------------------------------------------------
# ARGO WORKFLOWS CRDs (cluster-scoped; the controllers are per environment)
#
# Argo follows Dagster and MLflow: each environment runs its own controller +
# server in modules/workloads (namespace-scoped, optional workflow archive on
# that environment's database, its own private UI). CRDs are cluster-scoped
# and can have exactly one owner, so they are installed here, once, from the
# upstream minimal manifests at the pinned release -- the same split as KubeRay
# (operator here, RayClusters in workloads). The per-environment releases are
# installed with crds.install = false and no other cluster-scoped object.
#
# Keep argo_workflows_version in step with modules/workloads'
# argo_workflows_chart_version (the chart's appVersion); a newer controller
# than its CRDs is what breaks.
# ------------------------------------------------------------------------------

locals {
  argo_workflows_crds = var.enable_argo_workflows ? toset([
    "clusterworkflowtemplates",
    "cronworkflows",
    "workflowartifactgctasks",
    "workfloweventbindings",
    "workflows",
    "workflowtaskresults",
    "workflowtasksets",
    "workflowtemplates",
  ]) : toset([])
}

data "http" "argo_workflows_crd" {
  for_each = local.argo_workflows_crds

  url = "https://raw.githubusercontent.com/argoproj/argo-workflows/${var.argo_workflows_version}/manifests/base/crds/minimal/argoproj.io_${each.key}.yaml"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Could not fetch the Argo Workflows ${each.key} CRD for ${var.argo_workflows_version} (HTTP ${self.status_code}); check argo_workflows_version is a release tag like v4.1.3."
    }
  }
}

resource "kubectl_manifest" "argo_workflows_crd" {
  for_each = local.argo_workflows_crds

  yaml_body         = data.http.argo_workflows_crd[each.key].response_body
  server_side_apply = true
  wait              = true

  depends_on = [module.eks_blueprints_addons_core]
}
