locals {
  private_dns_suffix = var.private_ingress_dns_suffix != "" ? var.private_ingress_dns_suffix : "<your-suffix>"
}

output "webapp_namespace" {
  description = "Webapp namespace (if enabled)"
  value       = var.enable_webapp ? kubernetes_namespace_v1.webapp[0].metadata[0].name : null
}

output "dagster_namespace" {
  description = "Dagster namespace (if enabled)"
  value       = local.enable_dagster ? kubernetes_namespace_v1.dagster[0].metadata[0].name : null
}

output "mlflow_namespace" {
  description = "MLflow namespace (if enabled)"
  value       = var.enable_mlflow ? kubernetes_namespace_v1.mlflow[0].metadata[0].name : null
}

output "ray_namespace" {
  description = "Ray namespace (if enabled)"
  value       = var.enable_ray ? kubernetes_namespace_v1.ray[0].metadata[0].name : null
}

output "argo_namespace" {
  description = "Argo Workflows namespace (if enabled)"
  value       = var.enable_argo_workflows ? kubernetes_namespace_v1.argo[0].metadata[0].name : null
}

output "jupyterhub_namespace" {
  description = "JupyterHub namespace (if enabled)"
  value       = var.enable_jupyterhub ? kubernetes_namespace_v1.jupyterhub[0].metadata[0].name : null
}

# The identity contract's other half: the <namespace>/<serviceaccount> a
# backend adapter must trust for each service. Computed from inputs alone
# (name_prefix, webapp_app_name), so an adapter can be planned alongside this
# module without a dependency cycle -- aws/data-adapter derives the same names
# from the same inputs and this output exists to make that contract visible
# and testable.
output "service_accounts" {
  description = "Per-service {namespace, name} of the ServiceAccounts pods run as (null when the service is off). Backend adapters trust exactly these subjects."
  value = {
    webapp     = var.enable_webapp ? { namespace = local.webapp_namespace, name = local.webapp_service_account_name } : null
    dagster    = local.enable_dagster ? { namespace = local.dagster_namespace, name = local.dagster_service_account } : null
    ray        = var.enable_ray ? { namespace = local.ray_namespace, name = local.ray_service_account_name } : null
    argo       = var.enable_argo_workflows ? { namespace = local.argo_namespace, name = local.argo_service_account_name } : null
    mlflow     = var.enable_mlflow ? { namespace = local.mlflow_namespace, name = local.mlflow_service_account_name } : null
    jupyterhub = var.enable_jupyterhub ? { namespace = local.jupyterhub_namespace, name = local.jupyterhub_single_user_sa } : null
  }
}

output "identity_secret_names" {
  description = "Per-service name of the <service>-identity-env Secret (in that service's namespace) carrying workload_identity_secret_env; RayJobs launched by user code can envFrom the ray one."
  value       = local.identity_secret_name
}

output "in_cluster_urls" {
  description = "In-cluster URLs of the services THIS environment runs (null when a service is off). Another environment shares them by passing them as its mlflow_tracking_uri / dagster_webserver_url / argo_server_url with the matching enable_* off -- see README \"Stamp or share\"."
  value = {
    mlflow_tracking_uri   = var.enable_mlflow ? local.mlflow_tracking_uri : null
    dagster_webserver_url = local.enable_dagster ? local.dagster_webserver_url : null
    argo_server_url       = var.enable_argo_workflows ? local.argo_server_url : null
  }
}

output "dagster_private_url" {
  description = "Private URL for Dagit (if the private ingress + DNS suffix are set)"
  value       = var.enable_private_ingress && local.enable_dagster ? "https://${local.private_dagster_host}.${local.private_dns_suffix}" : null
}

output "mlflow_private_url" {
  description = "Private URL for the MLflow UI"
  value       = var.enable_private_ingress && var.enable_mlflow ? "https://${local.private_mlflow_host}.${local.private_dns_suffix}" : null
}

output "webapp_private_url" {
  description = "Private URL for the webapp"
  value       = var.enable_private_ingress && var.enable_webapp ? "https://${local.private_webapp_host}.${local.private_dns_suffix}" : null
}

output "ray_dashboard_private_url" {
  description = "Private URL for the Ray dashboard (502s while no Ray cluster is running)"
  value       = var.enable_private_ingress && var.enable_ray ? "https://${local.private_ray_host}.${local.private_dns_suffix}" : null
}

output "argo_private_url" {
  description = "Private URL for the Argo Workflows UI"
  value       = var.enable_private_ingress && var.enable_argo_workflows ? "https://${local.private_argo_host}.${local.private_dns_suffix}" : null
}

output "auth" {
  description = "How this environment authenticates (var.auth resolved): the mode, the issuer, the OAuth2 client ids it registered or expects (with the redirect URIs to register when bringing your own), which services sit behind an oauth2-proxy, and the browser-facing URL each redirect is built from."
  value = {
    mode          = var.auth.mode
    issuer_url    = local.auth_oidc ? var.auth.issuer_url : null
    dex_namespace = local.auth_dex ? var.auth.dex_namespace : null
    clients = {
      for k in keys(local.auth_clients_needed) : k => {
        client_id     = local.auth_client[k].id
        redirect_uris = local.auth_redirect_uris[k]
        dex_object    = local.auth_dex ? local.dex_client_object_name[k] : null
      }
    }
    proxied_services = sort(keys(local.proxied_services))
    external_urls    = local.auth_oidc ? local.auth_external_url : {}
  }
}

output "webapp_public_url" {
  description = "Public HTTPS URL for the webapp (null unless the public ingress is enabled)"
  value       = local.webapp_public_enabled ? "https://${var.webapp_public_host}" : null
}

output "webapp_public_ingress" {
  description = "{namespace, name} of the public webapp Ingress (null unless enabled), for adapters that look up the load balancer it produced"
  value       = local.webapp_public_enabled ? { namespace = local.webapp_namespace, name = local.webapp_public_ingress_name } : null
}
