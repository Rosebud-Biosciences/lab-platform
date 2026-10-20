# ------------------------------------------------------------------------------
# KUBERAY: CRDs + operator (cluster-scoped; the RayClusters are per environment)
#
# The operator chart ships its CRDs in crds/, which Helm installs once and
# never upgrades: after a chart bump the old schemas would stay, and the API
# server would silently drop every field they lack. So the CRDs are applied
# here from the release tag matching kuberay_operator_version (the pattern of
# the Argo Workflows CRDs, argo.tf) and the chart installs the operator alone.
#
# Like Helm, this never deletes them (apply_only): deleting a CRD deletes every
# object of its kind, i.e. every environment's RayClusters and RayJobs.
# ------------------------------------------------------------------------------

locals {
  kuberay_crds = var.enable_ray ? toset(["rayclusters", "raycronjobs", "rayjobs", "rayservices"]) : toset([])
}

data "http" "kuberay_crd" {
  for_each = local.kuberay_crds

  url = "https://raw.githubusercontent.com/kuberay-project/kuberay/v${var.kuberay_operator_version}/ray-operator/config/crd/bases/ray.io_${each.key}.yaml"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Could not fetch the KubeRay ${each.key} CRD for v${var.kuberay_operator_version} (HTTP ${self.status_code}); check kuberay_operator_version is a released version like 1.7.1."
    }
  }
}

resource "kubectl_manifest" "kuberay_crd" {
  for_each = local.kuberay_crds

  yaml_body         = data.http.kuberay_crd[each.key].response_body
  server_side_apply = true
  # A cluster installed before the CRDs moved here has them owned by Helm.
  force_conflicts = true
  apply_only      = true

  depends_on = [module.eks_blueprints_addons_core]
}

resource "helm_release" "kuberay_operator" {
  count = var.enable_ray ? 1 : 0

  name       = "kuberay-operator"
  repository = "https://ray-project.github.io/kuberay-helm/"
  chart      = "kuberay-operator"
  atomic     = true
  version    = var.kuberay_operator_version
  skip_crds  = true
  # modules/workloads' Ray NetworkPolicy admits the operator, which polls each
  # head's dashboard for RayJob status, from this namespace only
  # (network_policies.extra_namespaces).
  namespace        = "kuberay-system"
  create_namespace = true
  timeout          = 300

  depends_on = [module.eks_blueprints_addons_core, kubectl_manifest.kuberay_crd]
}
