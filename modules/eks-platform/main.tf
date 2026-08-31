# ------------------------------------------------------------------------------
# EKS PLATFORM MODULE - CORE CLUSTER
# ------------------------------------------------------------------------------

locals {
  # Cluster naming: eks-{environment} or eks-{environment}-{suffix}
  cluster_name = var.cluster_suffix != "" ? "eks-${var.environment}-${var.cluster_suffix}" : "eks-${var.environment}"

  # VPC name used by Karpenter node templates for subnet discovery.
  vpc_name = var.vpc_name != "" ? var.vpc_name : "vpc-${var.environment}"

  # Data-plane subnets: caller override, else all private subnets except those
  # in the secondary (pod) CIDR.
  derived_node_subnet_ids = compact([
    for subnet_id, cidr_block in zipmap(var.private_subnets, var.private_subnets_cidr_blocks) :
    substr(cidr_block, 0, length(var.secondary_vpc_cidr_octet_prefix)) == var.secondary_vpc_cidr_octet_prefix ? null : subnet_id
  ])
  eks_subnet_ids = length(var.node_subnet_ids) > 0 ? var.node_subnet_ids : local.derived_node_subnet_ids

  default_tags = {
    Terraform   = "true"
    Environment = var.environment
    Cluster     = local.cluster_name
  }

  tags = merge(local.default_tags, var.tags)
}

#tfsec:ignore:aws-eks-enable-control-plane-logging
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  # v21 dropped the `cluster_` prefix from most inputs to match the AWS API.
  name                    = local.cluster_name
  kubernetes_version      = var.eks_cluster_version
  endpoint_public_access  = var.cluster_endpoint_public_access
  endpoint_private_access = var.cluster_endpoint_private_access

  vpc_id     = var.vpc_id
  subnet_ids = local.eks_subnet_ids

  # EKS access entries (API mode) instead of the deprecated aws-auth ConfigMap.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  security_group_additional_rules = {
    ingress_nodes_ephemeral_ports_tcp = {
      description                = "Nodes on ephemeral ports"
      protocol                   = "tcp"
      from_port                  = 1025
      to_port                    = 65535
      type                       = "ingress"
      source_node_security_group = true
    }
    # Allow the VPC (i.e. admin via the private-access path) to reach the
    # private k8s API endpoint.
    ingress_to_cluster_sg_from_vpc = {
      description              = "Ingress to Cluster Security Group from VPC"
      protocol                 = "-1"
      from_port                = 0
      to_port                  = 0
      type                     = "ingress"
      source_security_group_id = var.vpc_security_group_id
    }
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    ingress_to_node_sg_from_vpc = {
      description              = "Ingress to Node Security Group from VPC"
      protocol                 = "-1"
      from_port                = 0
      to_port                  = 0
      type                     = "ingress"
      source_security_group_id = var.vpc_security_group_id
    }
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  # Core managed node group for the platform add-ons.
  eks_managed_node_groups = {
    infra = {
      name           = "core-node-group"
      instance_types = var.core_node_group_instance_types

      min_size     = var.core_node_group_min_size
      max_size     = var.core_node_group_max_size
      desired_size = var.core_node_group_desired_size
    }
  }

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.cluster_name
  })
}

# Charts hosted on public.ecr.aws (Karpenter, Kubecost) are pulled anonymously.
# We intentionally do NOT authenticate with an aws_ecrpublic_authorization_token:
# that token regenerates on every read, causing perpetual repository_password
# drift on those Helm releases.
