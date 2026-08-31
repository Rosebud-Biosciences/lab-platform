# ------------------------------------------------------------------------------
# PREVIEW EXAMPLE (workspace-per-PR)
#
# The flagship feature: branch prod for testing OFF prod. A preview stamps a
# unique `name_prefix` onto a full workload set that lands on the SHARED cluster,
# with its own copy-on-write Neon DB branches and an ephemeral S3 bucket. On
# `tofu destroy` (or the nightly sweep) every stamped resource -- namespaces,
# releases, IAM roles, NodePools, DB branches, bucket -- disappears; prod is
# untouched the whole time.
#
# Run one Terraform WORKSPACE per PR so each preview keeps isolated state:
#   tofu workspace new pr123
#   tofu apply -var preview_name=pr123
# ------------------------------------------------------------------------------

locals {
  name_prefix = "${var.preview_name}-"

  preview_tags = merge(var.tags, {
    Environment = "preview"
    Preview     = var.preview_name
    Terraform   = "true"
  })

  neon_enabled    = length(var.neon_branch_sources) > 0
  iceberg_enabled = var.iceberg_table_bucket_arn != ""
}

# In real use this stack needs its own remote backend: every preview job
# (up, migrate, teardown, sweep) runs `tofu init` on a fresh runner, so the
# pr<N> workspaces must live in shared state. Align workspace_key_prefix with
# the bootstrap module's preview_state_key_prefix (default preview/*) — with
# the backend default ("env:"), the preview role's state writes are denied:
#
# terraform {
#   backend "s3" {
#     bucket               = "<bootstrap: state_bucket_name>"
#     key                  = "app/terraform.tfstate"
#     region               = "us-west-2"
#     dynamodb_table       = "<bootstrap: lock_table_name>"
#     encrypt              = true
#     workspace_key_prefix = "preview" # pr<N> -> preview/pr<N>/app/terraform.tfstate
#   }
# }
#
# And resolve the shared cluster from the platform stack's state:
#
# data "terraform_remote_state" "platform" {
#   backend = "s3"
#   config = {
#     bucket = "my-org-terraform-state"
#     key    = "prod/platform/terraform.tfstate"
#     region = var.region
#   }
# }
# ...then pass data.terraform_remote_state.platform.outputs.cluster_name, etc.

# ------------------------------------------------------------------------------
# Disposable per-preview storage (apply first): an ephemeral processed-data
# bucket and copy-on-write Neon branches. Their outputs feed the workloads, so
# everything a preview writes is torn down on destroy.
# ------------------------------------------------------------------------------

module "storage" {
  source = "../../modules/preview-storage"

  name_prefix = var.preview_name
  tags        = local.preview_tags
}

module "neon" {
  source = "../../modules/neon-branches"

  providers = { neon = neon }

  name_prefix    = var.preview_name
  branch_sources = var.neon_branch_sources
}

# Ephemeral Iceberg namespace in the shared S3 Tables bucket (the lakehouse
# analogue of the Neon branches): the preview's jobs write tables only inside
# their own namespace and may read the listed prod namespaces, so no preview
# write can ever land in a prod table. Destroyed with the rest of the stamp;
# see modules/iceberg-branches for the teardown caveat (tables must be dropped
# before the namespace).
module "iceberg" {
  count  = local.iceberg_enabled ? 1 : 0
  source = "../../modules/iceberg-branches"

  name_prefix      = var.preview_name
  table_bucket_arn = var.iceberg_table_bucket_arn
  read_namespaces  = var.iceberg_read_namespaces
  tags             = local.preview_tags
}

module "workloads" {
  source = "../../modules/workloads"

  providers = {
    aws        = aws
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  environment = "preview"
  region      = var.region

  # Target the existing shared cluster.
  cluster_name                 = var.cluster_name
  oidc_provider_arn            = var.oidc_provider_arn
  vpc_name                     = var.vpc_name
  karpenter_node_iam_role_name = var.karpenter_node_iam_role_name

  # Everything is prefixed so it never collides with prod or other previews.
  name_prefix = local.name_prefix

  # Private Ingresses on the shared Tailscale operator, hostnames prefixed.
  enable_private_ingress          = var.private_ingress_dns_suffix != ""
  private_ingress_class_name      = "tailscale"
  private_ingress_hostname_prefix = local.name_prefix
  private_ingress_dns_suffix      = var.private_ingress_dns_suffix

  tags = local.preview_tags

  # Full workload set with a dedicated persistent Ray cluster for the preview.
  enable_webapp      = true
  webapp_image       = var.webapp_image
  enable_dagster     = true
  enable_ray         = true
  enable_ray_cluster = true
  enable_mlflow      = true

  # DB connections come from the ephemeral Neon branches (module.neon).
  database_url = local.neon_enabled ? module.neon.postgres_urls["app"] : ""

  dagster_db_host     = local.neon_enabled ? module.neon.connections["dagster"].host : ""
  dagster_db_name     = local.neon_enabled ? module.neon.connections["dagster"].dbname : ""
  dagster_db_user     = local.neon_enabled ? module.neon.connections["dagster"].user : ""
  dagster_db_password = local.neon_enabled ? module.neon.connections["dagster"].password : ""

  mlflow_db_host     = local.neon_enabled ? module.neon.connections["mlflow"].host : ""
  mlflow_db_name     = local.neon_enabled ? module.neon.connections["mlflow"].dbname : ""
  mlflow_db_user     = local.neon_enabled ? module.neon.connections["mlflow"].user : ""
  mlflow_db_password = local.neon_enabled ? module.neon.connections["mlflow"].password : ""

  # Storage: MLflow artifacts and the webapp's readable data both point at the
  # ephemeral bucket, so nothing a preview produces lands in a prod bucket.
  # Ray/Dagster additionally get the Iceberg policies when Iceberg is on:
  # read/write confined to the preview's namespace, read-only on prod's.
  mlflow_artifact_bucket     = module.storage.bucket_name
  mlflow_artifact_bucket_arn = module.storage.bucket_arn
  webapp_bucket_policies     = { processeddata = module.storage.get_policy_arn }
  ray_storage_bucket_policies = merge(
    { processeddata = module.storage.putget_policy_arn },
    local.iceberg_enabled ? { iceberg_rw = module.iceberg[0].readwrite_policy_arn } : {},
    local.iceberg_enabled && length(var.iceberg_read_namespaces) > 0
    ? { iceberg_read = module.iceberg[0].read_policy_arn } : {},
  )

  # Preview-scoped Karpenter NodePools (name-prefixed; scale to zero when idle,
  # torn down on destroy). Modest caps so a preview can't balloon cost.
  #
  # Unlike the source repo, the GPU pool is prefixed too: the Ray Helm values
  # select GPU workers by the name-prefixed NodePool, so each preview gets its
  # own isolated GPU capacity instead of sharing prod's.
  karpenter_node_pools = {
    default = {
      instance_families = ["m7i"]
      instance_sizes    = ["large", "xlarge"]
      capacity_types    = ["spot", "on-demand"]
      limits            = { cpu = "16", memory = "64Gi" }
    }
    ray-gpu-worker = {
      instance_families      = ["g6"]
      instance_sizes         = ["xlarge", "2xlarge"]
      instance_architectures = ["amd64"]
      capacity_types         = ["on-demand"]
      labels                 = { "nvidia.com/gpu" = "true" }
      limits                 = { "nvidia.com/gpu" = "4" }
      taints = [{
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NoSchedule"
      }]
    }
  }
}
