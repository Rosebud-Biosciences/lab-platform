# ------------------------------------------------------------------------------
# MINIMAL EXAMPLE
#
# The smallest useful stack: a VPC, an EKS cluster with the always-on platform
# add-ons (Karpenter, LB controller, metrics-server), and a single webapp
# workload. No Tailscale, no monitoring, no previews. Single shared NAT gateway
# and a public cluster endpoint keep it cheap and reachable from CI/laptops.
# ------------------------------------------------------------------------------

module "network" {
  source = "../../modules/network"

  name        = "vpc-${var.environment}"
  environment = var.environment

  # OSS-cheap defaults: one NAT gateway, no Tailscale router.
  single_nat_gateway             = true
  enable_tailscale_subnet_router = false

  tags = var.tags
}

module "platform" {
  source = "../../modules/eks-platform"

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

module "workloads" {
  source = "../../modules/workloads"

  providers = {
    aws        = aws
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  cluster_name                 = module.platform.cluster_name
  oidc_provider_arn            = module.platform.oidc_provider_arn
  region                       = var.region
  vpc_name                     = module.platform.vpc_name
  karpenter_node_iam_role_name = module.platform.karpenter_node_iam_role_name
  environment                  = var.environment

  enable_webapp = true
  webapp_image  = var.webapp_image

  tags = var.tags
}
