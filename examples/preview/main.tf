# ------------------------------------------------------------------------------
# PREVIEW EXAMPLE (workspace-per-PR)
#
# The flagship feature: branch prod for testing OFF prod. A preview stamps a
# unique `name_prefix` onto a full workload set that lands on the SHARED cluster,
# with its own copy-on-write Neon DB branches and an ephemeral S3 bucket. On
# `tofu destroy` (or the nightly sweep) every stamped resource -- namespaces,
# releases, IAM roles (aws/data-adapter), NodePools (aws/compute-adapter), DB
# branches, bucket -- disappears; prod is untouched the whole time.
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

  # "app": webapp only; the pipeline services are prod's (see variables.tf).
  pipelines = var.preview_profile == "full"

  # Preview-scoped Karpenter NodePools (name-prefixed by the adapter; scale to
  # zero when idle, torn down on destroy). Modest caps so a preview can't
  # balloon cost. The GPU pool is prefixed too, so RayJobs that select
  # module.compute.node_pool_names["ray-gpu-worker"] get isolated GPU capacity
  # instead of sharing prod's.
  preview_pools = {
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
  source = "../../aws/preview-storage"

  name_prefix = var.preview_name
  iam_path    = var.preview_iam_path
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
# see aws/iceberg-branches for the teardown caveat (tables must be dropped
# before the namespace).
module "iceberg" {
  count  = local.iceberg_enabled ? 1 : 0
  source = "../../aws/iceberg-branches"

  name_prefix      = var.preview_name
  table_bucket_arn = var.iceberg_table_bucket_arn
  read_namespaces  = var.iceberg_read_namespaces
  iam_path         = var.preview_iam_path
  tags             = local.preview_tags
}

# ------------------------------------------------------------------------------
# Backend adapters, stamped with the same prefix as the workloads.
# ------------------------------------------------------------------------------

# Data axis: per-service roles (IRSA on the shared EKS cluster). MLflow
# artifacts and the webapp's readable data both point at the ephemeral bucket,
# so nothing a preview produces lands in a prod bucket. Ray/Dagster
# additionally get the Iceberg policies when Iceberg is on: read/write confined
# to the preview's namespace, read-only on prod's.
locals {
  pipeline_policies = merge(
    { processeddata = module.storage.putget_policy_arn },
    local.iceberg_enabled ? { iceberg_rw = module.iceberg[0].readwrite_policy_arn } : {},
    local.iceberg_enabled && length(var.iceberg_read_namespaces) > 0
    ? { iceberg_read = module.iceberg[0].read_policy_arn } : {},
  )
}

module "data" {
  source = "../../aws/data-adapter"

  cluster_name      = var.cluster_name
  name_prefix       = local.name_prefix
  oidc_provider_arn = var.oidc_provider_arn
  region            = var.region

  # The preview role may create roles only here, and only with the boundary.
  iam_path                 = var.preview_iam_path
  permissions_boundary_arn = var.preview_permissions_boundary_arn

  enable_webapp  = true
  enable_dagster = local.pipelines
  enable_ray     = local.pipelines
  enable_mlflow  = local.pipelines

  webapp_policy_arns          = { processeddata = module.storage.get_policy_arn }
  dagster_policy_arns         = local.pipeline_policies
  ray_policy_arns             = local.pipeline_policies
  mlflow_artifact_bucket      = module.storage.bucket_name
  mlflow_artifact_bucket_arn  = module.storage.bucket_arn
  mlflow_artifact_kms_key_arn = module.storage.kms_key_arn

  tags = local.preview_tags
}

# Compute axis: the preview's Karpenter NodePools (local.preview_pools), with
# pipeline pods pinned to the preview's own default pool.
module "compute" {
  source = "../../aws/compute-adapter"

  providers = { aws = aws, helm = helm }

  cluster_name                 = var.cluster_name
  name_prefix                  = local.name_prefix
  environment                  = "preview"
  vpc_name                     = var.vpc_name
  karpenter_node_iam_role_name = var.karpenter_node_iam_role_name

  # No pipelines, no pools: an app-only preview rides the shared node group.
  # (A filtered for-expression rather than `cond ? pools : {}`: the two pool
  # objects differ in shape, which a conditional cannot unify.)
  karpenter_node_pools = { for k, v in local.preview_pools : k => v if local.pipelines }
  node_pool_roles      = { for k, v in { default = ["dagster", "ray_head", "ray_worker"] } : k => v if local.pipelines }

  tags = local.preview_tags
}

module "workloads" {
  source = "../../modules/workloads"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  environment = "preview"

  # Everything is prefixed so it never collides with prod or other previews.
  name_prefix = local.name_prefix

  # Contract inputs from the two adapters.
  workload_identity = module.data.workload_identity
  scheduling        = module.compute.scheduling

  # Private Ingresses on the shared Tailscale operator, hostnames prefixed.
  enable_private_ingress          = var.private_ingress_dns_suffix != ""
  private_ingress_class_name      = "tailscale"
  private_ingress_hostname_prefix = local.name_prefix
  private_ingress_dns_suffix      = var.private_ingress_dns_suffix

  # preview_profile "full": the whole set with a dedicated persistent Ray
  # cluster. "app": the webapp alone, pointed at prod's Dagster and MLflow --
  # the same env var names, different targets (workloads README "Stamp or
  # share").
  enable_webapp      = true
  webapp_image       = var.webapp_image
  enable_dagster     = local.pipelines
  enable_ray         = local.pipelines
  enable_ray_cluster = local.pipelines
  enable_mlflow      = local.pipelines

  dagster_webserver_url = local.pipelines ? "" : var.shared_service_urls.dagster_webserver_url
  mlflow_tracking_uri   = local.pipelines ? "" : var.shared_service_urls.mlflow_tracking_uri

  # DB connections come from the ephemeral Neon branches (module.neon). The
  # webapp AND Dagster's user-code deployment (hence every run it launches)
  # receive database_url as DATABASE_URL; dagster_user_code_env /
  # dagster_user_code_secret_env carry anything else the assets need.
  database_url = local.neon_enabled ? module.neon.postgres_urls["app"] : ""

  dagster_db_host     = local.neon_enabled ? module.neon.connections["dagster"].host : ""
  dagster_db_name     = local.neon_enabled ? module.neon.connections["dagster"].dbname : ""
  dagster_db_user     = local.neon_enabled ? module.neon.connections["dagster"].user : ""
  dagster_db_password = local.neon_enabled ? module.neon.connections["dagster"].password : ""

  mlflow_db_host     = local.neon_enabled ? module.neon.connections["mlflow"].host : ""
  mlflow_db_name     = local.neon_enabled ? module.neon.connections["mlflow"].dbname : ""
  mlflow_db_user     = local.neon_enabled ? module.neon.connections["mlflow"].user : ""
  mlflow_db_password = local.neon_enabled ? module.neon.connections["mlflow"].password : ""

  mlflow_artifact_root = module.data.mlflow_artifact_root
}
