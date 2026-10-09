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
  # The Karpenter node entry is separate (addons.tf); everything else that may
  # reach the API is either the creator or listed in var.access_entries.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  access_entries                           = var.access_entries

  # The module creates clusters without EKS's own CNI and kube-proxy
  # (bootstrap_self_managed_addons is hard-coded off), and a node never turns
  # Ready without them. They must wait for the cluster alone: anything behind
  # the kubernetes/helm providers waits for the node groups too
  # (terraform_data.cluster_access), the blueprints module's add-ons included,
  # so installed there they deadlock a new cluster's first apply. The other
  # add-ons need nodes and stay there (addons.tf).
  addons = {
    vpc-cni = merge(
      {
        before_compute = true
        addon_version  = "v1.23.0-eksbuild.1"
        preserve       = true
      },
      # The CNI's network policy agent: without it every NetworkPolicy
      # (modules/workloads network_policies) is accepted and ignored.
      var.enable_network_policy ? { configuration_values = jsonencode({ enableNetworkPolicy = "true" }) } : {},
    )
    kube-proxy = {
      before_compute = true
      addon_version  = "v1.35.3-eksbuild.18"
      preserve       = true
    }
  }

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

# The path an operator's kubernetes/helm/kubectl providers take to the API:
# the cluster, its nodes and the security group rule that admits the VPC's
# admin path (module.eks), and whatever var.cluster_access_dependencies names
# (the relay in front of a private endpoint). The cluster_endpoint output is
# read through this node, so a stack whose providers use it destroys every
# in-cluster resource before any part of that path: neither a full nor a
# targeted destroy can cut its own access while in-cluster deletes remain.
resource "terraform_data" "cluster_access" {
  input            = module.eks.cluster_endpoint
  triggers_replace = var.cluster_access_dependencies

  depends_on = [module.eks]
}

# Charts hosted on public.ecr.aws (Karpenter, Kubecost) are pulled anonymously.
# We intentionally do NOT authenticate with an aws_ecrpublic_authorization_token:
# that token regenerates on every read, causing perpetual repository_password
# drift on those Helm releases.

# Clusters created before 0.3.0 hold these two at the blueprints module's
# addresses: re-addressed, not reinstalled.
moved {
  from = module.eks_blueprints_addons_core.aws_eks_addon.this["vpc-cni"]
  to   = module.eks.aws_eks_addon.before_compute["vpc-cni"]
}

moved {
  from = module.eks_blueprints_addons_core.aws_eks_addon.this["kube-proxy"]
  to   = module.eks.aws_eks_addon.before_compute["kube-proxy"]
}
