# ------------------------------------------------------------------------------
# COMPLETE EXAMPLE
#
# The full surface: a VPC with a Tailscale subnet router, an EKS cluster with
# monitoring + Kubecost + FluentBit + GPU support + KubeRay + Argo + the
# Tailscale operator, a hardened S3 bucket for MLflow artifacts, and every
# workload (public webapp, JupyterHub, Dagster, MLflow, a persistent Ray
# cluster) fronted by private Tailscale Ingresses.
#
# This is intentionally expensive; treat it as a reference for the wiring, not a
# default to apply verbatim. See examples/minimal for the cheap path.
# ------------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  tailscale_enabled = var.tailscale_oauth_client_id != "" && var.tailscale_oauth_client_secret != ""

  # Globally-unique, stable artifact bucket name.
  mlflow_bucket_name = "lab-platform-mlflow-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

module "network" {
  source = "../../aws/network"

  name        = "vpc-${var.environment}"
  environment = var.environment

  # HA production posture: one NAT gateway per AZ.
  single_nat_gateway = false

  # Private admin access to the cluster API via a Tailscale subnet router.
  enable_tailscale_subnet_router = local.tailscale_enabled
  ts_relay_client_id             = var.tailscale_oauth_client_id
  ts_relay_client_secret         = var.tailscale_oauth_client_secret

  tags = var.tags
}

module "artifacts" {
  source = "../../aws/s3-bucket"

  name = local.mlflow_bucket_name
  tags = var.tags
}

module "platform" {
  source = "../../aws/eks-platform"

  providers = {
    aws                   = aws
    aws.ecr_public_region = aws.ecr_public_region
    kubernetes            = kubernetes
    helm                  = helm
    kubectl               = kubectl
  }

  environment = var.environment
  region      = var.region

  vpc_id                      = module.network.vpc_id
  vpc_name                    = module.network.vpc_name
  private_subnets             = module.network.private_subnets
  private_subnets_cidr_blocks = module.network.private_subnets_cidr_blocks

  # Trust the Tailscale relay SG for private admin access (falls back to the
  # VPC default SG when the router is off).
  vpc_security_group_id = local.tailscale_enabled ? module.network.tailscale_security_group_id : module.network.default_security_group_id

  # Private-only API endpoint (reachable over the tailnet).
  cluster_endpoint_public_access  = !local.tailscale_enabled
  cluster_endpoint_private_access = true

  # Full operator surface.
  enable_kube_prometheus = true
  enable_kubecost        = true
  enable_aws_fluentbit   = true
  enable_gpu_support     = true
  enable_ray             = true
  enable_argo_workflows  = true

  enable_tailscale_operator     = local.tailscale_enabled
  tailscale_oauth_client_id     = var.tailscale_oauth_client_id
  tailscale_oauth_client_secret = var.tailscale_oauth_client_secret

  # Public hostnames follow the Ingresses: workloads stamps the external-dns
  # hostname annotation, external-dns writes the Route53 record.
  enable_external_dns            = var.webapp_route53_zone_id != ""
  external_dns_route53_zone_arns = var.webapp_route53_zone_id != "" ? ["arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.webapp_route53_zone_id}"] : []

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Backend adapters: the two axes of the AWS backend, feeding the portable
# workloads module its contract inputs.
# ------------------------------------------------------------------------------

# Data axis: per-service IAM roles (IRSA -- compute and data share the cloud).
module "data" {
  source = "../../aws/data-adapter"

  cluster_name      = module.platform.cluster_name
  oidc_provider_arn = module.platform.oidc_provider_arn
  region            = var.region

  enable_webapp         = true
  enable_ray            = true
  enable_dagster        = true
  enable_argo_workflows = true
  enable_mlflow         = true
  enable_jupyterhub     = true

  mlflow_artifact_bucket      = module.artifacts.aws_s3_bucket.bucket
  mlflow_artifact_bucket_arn  = module.artifacts.aws_s3_bucket.arn
  mlflow_artifact_kms_key_arn = module.artifacts.aws_kms_key_arn

  tags = var.tags
}

# Compute axis: EFS for JupyterHub, the ALB/ACM/WAF edge, a GPU NodePool.
module "compute" {
  source = "../../aws/compute-adapter"

  providers = { aws = aws, helm = helm }

  cluster_name                 = module.platform.cluster_name
  environment                  = var.environment
  vpc_name                     = module.platform.vpc_name
  karpenter_node_iam_role_name = module.platform.karpenter_node_iam_role_name

  enable_jupyterhub           = true
  vpc_id                      = module.network.vpc_id
  private_subnets             = module.network.private_subnets
  private_subnets_cidr_blocks = module.network.private_subnets_cidr_blocks
  vpc_secondary_cidr_blocks   = module.network.vpc_secondary_cidr_blocks

  enable_webapp_public_ingress = var.webapp_public_host != ""
  webapp_acm_certificate_arn   = var.webapp_acm_certificate_arn
  enable_webapp_waf            = var.webapp_public_host != ""

  # GPU NodePool for Ray GPU workers. Nothing in the persistent cluster selects
  # it; RayJobs that need GPUs set nodeSelector karpenter.sh/nodepool = "gpu"
  # (module.compute.node_pool_names.gpu) and tolerate nvidia.com/gpu.
  karpenter_node_pools = {
    gpu = {
      instance_families      = ["g5", "g6"]
      instance_sizes         = ["xlarge", "2xlarge"]
      instance_architectures = ["amd64"]
      capacity_types         = ["on-demand"]
      labels                 = { "nvidia.com/gpu" = "true" }
      taints = [{
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NoSchedule"
      }]
    }
  }

  tags = var.tags
}

module "workloads" {
  source = "../../modules/workloads"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  environment = var.environment

  # Contract inputs from the two adapters.
  workload_identity                 = module.data.workload_identity
  scheduling                        = module.compute.scheduling
  jupyterhub_shared_storage         = module.compute.jupyterhub_shared_storage
  webapp_public_ingress_class_name  = module.compute.webapp_public_ingress_class_name
  webapp_public_ingress_annotations = module.compute.webapp_public_ingress_annotations

  # Private Ingresses via the Tailscale operator's IngressClass.
  enable_private_ingress          = local.tailscale_enabled
  private_ingress_class_name      = "tailscale"
  private_ingress_dns_suffix      = var.tailscale_dns_suffix
  private_ingress_hostname_prefix = ""

  # --- Webapp (public ALB) ---
  enable_webapp                = true
  webapp_image                 = var.webapp_image
  database_url                 = var.app_database_url
  enable_webapp_public_ingress = var.webapp_public_host != ""
  webapp_public_host           = var.webapp_public_host

  # --- JupyterHub ---
  enable_jupyterhub        = true
  jupyterhub_user_password = var.jupyterhub_user_password

  # --- Ray + Dagster ---
  enable_ray          = true
  enable_ray_cluster  = true
  enable_dagster      = true
  dagster_db_host     = var.dagster_db.host
  dagster_db_name     = var.dagster_db.name
  dagster_db_user     = var.dagster_db.user
  dagster_db_password = var.dagster_db.password

  # --- Argo Workflows (per environment; archive when a database is given) ---
  enable_argo_workflows        = true
  enable_argo_workflow_archive = var.argo_db.host != ""
  argo_db_host                 = var.argo_db.host
  argo_db_name                 = var.argo_db.name
  argo_db_user                 = var.argo_db.user
  argo_db_password             = var.argo_db.password

  # --- MLflow (artifacts to the hardened S3 bucket) ---
  enable_mlflow        = true
  mlflow_artifact_root = module.data.mlflow_artifact_root
  mlflow_db_host       = var.mlflow_db.host
  mlflow_db_name       = var.mlflow_db.name
  mlflow_db_user       = var.mlflow_db.user
  mlflow_db_password   = var.mlflow_db.password
}
