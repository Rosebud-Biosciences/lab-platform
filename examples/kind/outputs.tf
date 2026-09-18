output "namespaces" {
  description = "Where everything landed"
  value = {
    webapp     = module.workloads.webapp_namespace
    dagster    = module.workloads.dagster_namespace
    ray        = module.workloads.ray_namespace
    mlflow     = module.workloads.mlflow_namespace
    argo       = module.workloads.argo_namespace
    jupyterhub = module.workloads.jupyterhub_namespace
  }
}

output "service_accounts" {
  description = "The identity contract's subjects (what an adapter would have to trust)"
  value       = module.workloads.service_accounts
}

output "port_forwards" {
  description = "Reach the UIs from the laptop"
  value = {
    dagster = "kubectl -n ${module.workloads.dagster_namespace} port-forward svc/${var.name_prefix}dagster-dagster-webserver 3000:80   # http://localhost:3000"
    mlflow  = "kubectl -n ${module.workloads.mlflow_namespace} port-forward svc/${var.name_prefix}mlflow 5000:80                      # http://localhost:5000"
    webapp  = "kubectl -n ${module.workloads.webapp_namespace} port-forward svc/webapp 8080:80                                      # http://localhost:8080"
    argo    = "kubectl -n ${module.workloads.argo_namespace} port-forward svc/${var.name_prefix}argo-server 2746:2746                 # http://localhost:2746"
    ray     = "kubectl -n ${module.workloads.ray_namespace} port-forward svc/${var.name_prefix}ray-cluster-head-svc 8265:8265  # http://localhost:8265"
    s3      = "kubectl -n seaweedfs port-forward svc/seaweedfs 8333:8333 8888:8888                                              # S3 API :8333, filer UI http://localhost:8888"
  }
}
