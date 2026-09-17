# ------------------------------------------------------------------------------
# MINIMAL EXAMPLE
#
# The smallest useful stack: a VPC, an EKS cluster with the always-on platform
# add-ons (Karpenter, LB controller, metrics-server), and a single webapp
# workload. No Tailscale, no monitoring, no previews. Single shared NAT gateway
# and a public cluster endpoint keep it cheap and reachable from CI/laptops.
# ------------------------------------------------------------------------------

module "network" {
  source = "../../aws/network"

  name        = "vpc-${var.environment}"
  environment = var.environment

  # OSS-cheap defaults: one NAT gateway, no Tailscale router.
  single_nat_gateway             = true
  enable_tailscale_subnet_router = false

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
  vpc_security_group_id       = module.network.default_security_group_id

  # Reachable from CI/laptops without a bastion/VPN for this minimal demo.
  cluster_endpoint_public_access = true

  tags = var.tags
}

# The workloads layer needs nothing from AWS to run a webapp: no adapters, no
# aws provider. Add aws/data-adapter when the app must reach S3, and
# aws/compute-adapter for EFS / a public ALB / Karpenter pools (see
# examples/complete).
module "workloads" {
  source = "../../modules/workloads"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  environment = var.environment

  enable_webapp = true
  webapp_image  = var.webapp_image

  depends_on = [module.platform]
}
