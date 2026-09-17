output "jupyterhub_shared_storage" {
  description = "The jupyterhub_shared_storage input for modules/workloads: static NFS PersistentVolumes on the EFS filesystem (nfs_server is null when JupyterHub is off, which workloads accepts while enable_jupyterhub is false)"
  value = {
    nfs_server         = var.enable_jupyterhub ? local.jupyterhub_efs.dns_name : null
    nfs_path           = "/"
    storage_class_name = null
    size               = var.jupyterhub_storage_size
  }
}

output "jupyterhub_efs_id" {
  description = "EFS filesystem id holding JupyterHub per-user home and shared directories (null when off) -- the only persistent user data in the workloads layer; point AWS Backup here"
  value       = var.enable_jupyterhub ? local.jupyterhub_efs.id : null
}

output "webapp_public_ingress_class_name" {
  description = "The webapp_public_ingress_class_name input for modules/workloads (the AWS Load Balancer Controller's class)"
  value       = "alb"
}

output "webapp_public_ingress_annotations" {
  description = "The webapp_public_ingress_annotations input for modules/workloads: internet-facing ALB, ACM TLS with 80->443 redirect, health check, optional stickiness and WAF ACL; {} when the public ingress is off"
  value       = local.webapp_public_ingress_annotations
}

output "jupyterhub_public_ingress_class_name" {
  description = "The jupyterhub_public_ingress_class_name input for modules/workloads"
  value       = "alb"
}

output "jupyterhub_public_ingress_annotations" {
  description = "The jupyterhub_public_ingress_annotations input for modules/workloads (ALB scheme, target type, optional ACM TLS)"
  value       = local.jupyterhub_public_ingress_annotations
}

output "scheduling" {
  description = "The scheduling input for modules/workloads: karpenter.sh/nodepool selectors and taint tolerations for every role listed in node_pool_roles"
  value       = local.scheduling
}

output "node_pool_names" {
  description = "Rendered (prefixed) NodePool names by karpenter_node_pools key"
  value       = local.pool_name
}

output "webapp_waf_acl_arn" {
  description = "WAFv2 web ACL ARN attached to the public webapp ALB (null when off)"
  value       = local.webapp_waf_enabled ? aws_wafv2_web_acl.webapp[0].arn : null
}
