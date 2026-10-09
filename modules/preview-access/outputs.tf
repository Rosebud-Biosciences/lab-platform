output "group" {
  description = "Kubernetes group to map the preview deploy identity to (an EKS access entry's kubernetes_groups)"
  value       = var.group
}

output "cluster_role_name" {
  description = "The ClusterRole bound to group"
  value       = kubernetes_cluster_role_v1.this.metadata[0].name
}

output "namespace_admin_cluster_role" {
  description = "The ClusterRole a preview binds to group in each namespace it creates (modules/workloads namespace_admin.cluster_role)"
  value       = kubernetes_cluster_role_v1.namespace_admin.metadata[0].name
}
