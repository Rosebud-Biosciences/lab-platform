# ------------------------------------------------------------------------------
# Multi-AZ VPC with public / private / intra / database tiers and a secondary
# CIDR for EKS pod IPs. The AWS and Tailscale providers are configured by the
# caller and passed in; this module declares no provider blocks so it can be
# used with count/for_each and published to the registry.
# ------------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name        = var.name
  environment = var.environment

  # Karpenter/EKS discovery tag on the private subnets.
  discovery_name = var.cluster_name != "" ? var.cluster_name : "eks-${local.environment}"

  vpc_cidr           = var.vpc_cidr
  secondary_vpc_cidr = var.secondary_vpc_cidr
  azs                = slice(data.aws_availability_zones.available.names, 0, var.num_availability_zones)

  # Enough newbits to give every AZ its own slice of the secondary (pod) CIDR.
  # A fixed newbits of 1 only spans two AZs; the default is three.
  secondary_newbits = max(1, ceil(log(length(local.azs), 2)))

  private_subnets                    = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets                     = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  secondary_ip_range_private_subnets = [for k, v in local.azs : cidrsubnet(local.secondary_vpc_cidr, local.secondary_newbits, k)]
  intra_subnets                      = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]
  database_subnets                   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 56)]

  tags = local.tags_all
  tags_all = merge(var.tags, {
    Environment = local.environment
  })
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = local.vpc_cidr
  azs  = local.azs

  secondary_cidr_blocks = [local.secondary_vpc_cidr]

  private_subnets  = concat(local.private_subnets, local.secondary_ip_range_private_subnets)
  public_subnets   = local.public_subnets
  intra_subnets    = local.intra_subnets # control-plane subnets
  database_subnets = local.database_subnets

  map_public_ip_on_launch = true
  enable_nat_gateway      = true
  single_nat_gateway      = var.single_nat_gateway
  one_nat_gateway_per_az  = !var.single_nat_gateway
  enable_dns_hostnames    = true

  enable_flow_log                      = true
  create_flow_log_cloudwatch_iam_role  = true
  create_flow_log_cloudwatch_log_group = true

  # Lets the AWS Load Balancer Controller auto-discover subnets by tag:
  # internet-facing ALBs in the public subnets, internal ones in the private
  # subnets. The Karpenter discovery tag matches the cluster name.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.discovery_name
  }

  tags = local.tags
}

# ------------------------------------------------------------------------------
# VPC Endpoints
# Gateway endpoints (S3, DynamoDB) are free; interface endpoints have a small
# hourly cost but avoid NAT data-processing charges for AWS service traffic.
# ------------------------------------------------------------------------------

module "vpc_endpoints" {
  count = var.enable_vpc_endpoints ? 1 : 0

  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 6.0"

  vpc_id = module.vpc.vpc_id

  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags            = { Name = "${local.name}-s3" }
    }
    dynamodb = {
      service         = "dynamodb"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags            = { Name = "${local.name}-dynamodb" }
    }
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = slice(module.vpc.private_subnets, 0, length(local.azs))
      tags                = { Name = "${local.name}-ecr-api" }
    }
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = slice(module.vpc.private_subnets, 0, length(local.azs))
      tags                = { Name = "${local.name}-ecr-dkr" }
    }
    sts = {
      service             = "sts"
      private_dns_enabled = true
      subnet_ids          = slice(module.vpc.private_subnets, 0, length(local.azs))
      tags                = { Name = "${local.name}-sts" }
    }
    logs = {
      service             = "logs"
      private_dns_enabled = true
      subnet_ids          = slice(module.vpc.private_subnets, 0, length(local.azs))
      tags                = { Name = "${local.name}-logs" }
    }
    ec2 = {
      service             = "ec2"
      private_dns_enabled = true
      subnet_ids          = slice(module.vpc.private_subnets, 0, length(local.azs))
      tags                = { Name = "${local.name}-ec2" }
    }
    elasticloadbalancing = {
      service             = "elasticloadbalancing"
      private_dns_enabled = true
      subnet_ids          = slice(module.vpc.private_subnets, 0, length(local.azs))
      tags                = { Name = "${local.name}-elb" }
    }
  }

  create_security_group      = true
  security_group_name_prefix = "${local.name}-vpc-endpoints-"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from VPC"
      cidr_blocks = [local.vpc_cidr, local.secondary_vpc_cidr]
    }
  }

  tags = local.tags
}
