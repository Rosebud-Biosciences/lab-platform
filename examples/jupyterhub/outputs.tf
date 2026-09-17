output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.platform.cluster_name
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "jupyterhub_namespace" {
  description = "Namespace JupyterHub runs in"
  value       = module.workloads.jupyterhub_namespace
}

output "jupyterhub_efs_id" {
  description = "EFS filesystem holding user home + shared directories (destroy-protected; point AWS Backup here)"
  value       = module.compute.jupyterhub_efs_id
}

output "kubeconfig_command" {
  description = "Command to point kubectl at the new cluster"
  value       = "aws eks update-kubeconfig --name ${module.platform.cluster_name} --region ${var.region}"
}

output "port_forward_command" {
  description = "Open the hub locally (no ingress in this example)"
  value       = "kubectl port-forward -n ${module.workloads.jupyterhub_namespace} svc/proxy-public 8080:80"
}
