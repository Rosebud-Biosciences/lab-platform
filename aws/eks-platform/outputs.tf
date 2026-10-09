# ------------------------------------------------------------------------------
# CLUSTER
# ------------------------------------------------------------------------------

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "The endpoint for the EKS cluster API server. Configure the kubernetes/helm/kubectl providers from this output: it carries the dependency on the API access path, which orders in-cluster resources' destruction before that path's (terraform_data.cluster_access)."
  value       = terraform_data.cluster_access.input
  sensitive   = true
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_version" {
  description = "The Kubernetes version for the EKS cluster"
  value       = module.eks.cluster_version
}

output "cluster_arn" {
  description = "The ARN of the EKS cluster"
  value       = module.eks.cluster_arn
}

# ------------------------------------------------------------------------------
# OIDC / IRSA
# ------------------------------------------------------------------------------

output "oidc_provider_arn" {
  description = "The ARN of the IRSA OIDC provider"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider" {
  description = "The OIDC provider URL (without protocol)"
  value       = module.eks.oidc_provider
}

# ------------------------------------------------------------------------------
# SECURITY GROUPS
# ------------------------------------------------------------------------------

output "cluster_security_group_id" {
  description = "ID of the cluster security group"
  value       = module.eks.cluster_security_group_id
}

output "cluster_primary_security_group_id" {
  description = "ID of the cluster primary security group"
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "ID of the node security group"
  value       = module.eks.node_security_group_id
}

# ------------------------------------------------------------------------------
# NODE GROUPS / KARPENTER
# ------------------------------------------------------------------------------

output "eks_managed_node_groups" {
  description = "Map of EKS managed node groups created"
  value       = module.eks.eks_managed_node_groups
}

output "karpenter_node_iam_role_arn" {
  description = "ARN of the Karpenter node IAM role (consumed by the workloads module NodePools)"
  value       = var.enable_karpenter ? module.eks_blueprints_addons.karpenter.node_iam_role_arn : null
}

output "karpenter_node_iam_role_name" {
  description = "Name of the Karpenter node IAM role (used by NodePool nodeRole)"
  value       = var.enable_karpenter ? module.eks_blueprints_addons.karpenter.node_iam_role_name : null
}

output "vpc_name" {
  description = "VPC name used for Karpenter subnet/SG discovery"
  value       = local.vpc_name
}

# ------------------------------------------------------------------------------
# MISC
# ------------------------------------------------------------------------------

output "region" {
  description = "AWS region"
  value       = var.region
}

output "environment" {
  description = "Environment name"
  value       = var.environment
}

output "grafana_secret_name" {
  description = "Name of the Grafana admin password secret in Secrets Manager (when monitoring is enabled)"
  value       = var.enable_kube_prometheus ? aws_secretsmanager_secret.grafana[0].name : null
}

output "tailscale_operator_enabled" {
  description = "Whether the Tailscale operator (and its 'tailscale' IngressClass) is installed"
  # nonsensitive(): this is a presence boolean derived from a sensitive OAuth
  # client id, but the flag itself leaks nothing.
  value = nonsensitive(local.enable_tailscale_operator)
}

output "external_dns_enabled" {
  description = "Whether external-dns runs on this cluster (public Ingress hostnames then resolve without tofu-managed records)"
  value       = var.enable_external_dns
}

output "preview_access_group" {
  description = "Kubernetes group for the preview deploy identity's access entry (null without preview_access)"
  value       = one(module.preview_access[*].group)
}

output "preview_namespace_admin_cluster_role" {
  description = "ClusterRole a preview binds to preview_access_group in each namespace it creates: its modules/workloads namespace_admin.cluster_role (null without preview_access)"
  value       = one(module.preview_access[*].namespace_admin_cluster_role)
}
