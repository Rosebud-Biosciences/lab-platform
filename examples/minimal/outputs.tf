output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.platform.cluster_name
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "webapp_namespace" {
  description = "Namespace the demo webapp runs in"
  value       = module.workloads.webapp_namespace
}

output "kubeconfig_command" {
  description = "Command to point kubectl at the new cluster"
  value       = "aws eks update-kubeconfig --name ${module.platform.cluster_name} --region ${var.region}"
}
