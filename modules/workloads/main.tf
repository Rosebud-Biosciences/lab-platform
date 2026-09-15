# ------------------------------------------------------------------------------
# SHARED LOCALS: prefixed names, image tags, private hostnames.
# name_prefix = "" reproduces the base names so this module is a drop-in for a
# single-environment deployment; a non-empty prefix isolates a preview.
# ------------------------------------------------------------------------------

locals {
  prefix = var.name_prefix

  # Parenthetical note appended to IAM policy descriptions so previews are
  # distinguishable.
  iam_desc_suffix = local.prefix != "" ? " (${local.prefix})" : ""

  # This module owns its own Helm value templates.
  helm_defaults = "${path.module}/helm-defaults"

  webapp_namespace  = "${local.prefix}${var.webapp_app_name}"
  dagster_namespace = "${local.prefix}dagster"
  mlflow_namespace  = "${local.prefix}mlflow"
  ray_namespace     = "${local.prefix}ray"

  webapp_service_account_name = var.webapp_app_name
  dagster_service_account     = "dagster"
  mlflow_service_account_name = "mlflow"

  # Helm release names (the chart derives resource/service names from these).
  dagster_release = "${local.prefix}dagster"
  mlflow_release  = "${local.prefix}mlflow"

  # Chart-derived service names used by the private Ingress backends.
  dagster_webserver_service = "${local.dagster_release}-dagster-webserver"
  mlflow_service            = local.mlflow_release

  # Dagster requires Ray. This is an explicit precondition (see the check block)
  # rather than the old silent `enable_dagster && enable_ray`.
  enable_dagster = var.enable_dagster

  ray_image_tag     = var.ray_image_tag != "" ? var.ray_image_tag : var.ray_version
  ray_gpu_image_tag = var.ray_gpu_image_tag != "" ? var.ray_gpu_image_tag : "${var.ray_version}-gpu"

  # In-cluster MLflow tracking URI (namespaced so previews don't hit prod).
  mlflow_tracking_uri = var.enable_mlflow ? "http://${local.mlflow_service}.${local.mlflow_namespace}.svc.cluster.local:80" : ""

  # Private hostnames (unique per env via the prefix).
  private_dagster_host = "${var.private_ingress_hostname_prefix}dagster"
  private_mlflow_host  = "${var.private_ingress_hostname_prefix}mlflow"
  private_webapp_host  = "${var.private_ingress_hostname_prefix}webapp"
  private_ray_host     = "${var.private_ingress_hostname_prefix}ray"

  create_pools = var.karpenter_node_iam_role_name != "" ? var.karpenter_node_pools : {}
}

# ------------------------------------------------------------------------------
# KARPENTER NODEPOOLS (per workload env; names prefixed so previews get their
# own pools that scale to zero and are torn down on destroy).
# ------------------------------------------------------------------------------

resource "helm_release" "karpenter_node_pools" {
  for_each = local.create_pools

  namespace        = "karpenter"
  create_namespace = false
  name             = "karpenter-resources-${local.prefix}${each.key}"
  chart            = "${local.helm_defaults}/karpenter-resources"

  values = [
    yamlencode({
      name                  = "${local.prefix}${coalesce(each.value.name, each.key)}"
      clusterName           = var.cluster_name
      vpcName               = var.vpc_name
      nodeRole              = var.karpenter_node_iam_role_name
      instanceSizes         = each.value.instance_sizes
      instanceFamilies      = each.value.instance_families
      instanceArchitectures = each.value.instance_architectures
      capacityTypes         = each.value.capacity_types
      amiFamily             = each.value.ami_family
      labels                = each.value.labels
      taints                = [for t in each.value.taints : { for k, v in t : k => v if v != null }]
      limits                = each.value.limits
    })
  ]
}
