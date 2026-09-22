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
  description = "Reach the UIs from the laptop. The OIDC redirects point at in-cluster hostnames, so a browser login needs those names to resolve to the forwarded ports (see the README); the health endpoints work as-is."
  value = {
    dagster = "kubectl -n ${module.workloads.dagster_namespace} port-forward svc/${var.name_prefix}dagster-dagster-webserver 3000:80   # http://localhost:3000 (bypasses the auth proxy)"
    mlflow  = "kubectl -n ${module.workloads.mlflow_namespace} port-forward svc/${var.name_prefix}mlflow 5000:80                      # http://localhost:5000 (bypasses the auth proxy)"
    webapp  = "kubectl -n ${module.workloads.webapp_namespace} port-forward svc/webapp 8080:80                                      # http://localhost:8080"
    argo    = "kubectl -n ${module.workloads.argo_namespace} port-forward svc/${var.name_prefix}argo-server 2746:2746                 # http://localhost:2746 (SSO: log in via Dex)"
    ray     = "kubectl -n ${module.workloads.ray_namespace} port-forward svc/${var.name_prefix}ray-cluster-head-svc 8265:8265  # http://localhost:8265"
    dex     = "kubectl -n ${module.dex.namespace} port-forward svc/${module.dex.service_name} 5556:5556                                       # http://localhost:5556/dex/.well-known/openid-configuration"
    s3      = "kubectl -n seaweedfs port-forward svc/seaweedfs 8333:8333 8888:8888                                              # S3 API :8333, filer UI http://localhost:8888"
  }
}

output "auth" {
  description = "The environment's auth wiring: issuer, registered Dex clients (with their redirect URIs), proxied services"
  value       = module.workloads.auth
}

output "logins" {
  description = "How to log in through Dex"
  value = var.enable_keycloak ? {
    for name, groups in local.kind_users : name => "${name}@example.com / kind_users_password (\"password\"); groups: ${length(groups) > 0 ? join(", ", groups) : "none"}"
    } : {
    password_db = "${var.dex_admin_email} / the password behind dex_admin_password_hash (\"password\" by default); no groups, so MLflow and Ray open, Dagster refuses"
    mock        = "Dex's 'Example (mock user, group authors)' button: kilgore@kilgore.trout in group authors; opens everything"
  }
}

output "tenant_stamps" {
  description = "Per tenant, the namespaces of its isolated services"
  value = {
    for t, stamp in module.tenancy.stamps : t => {
      for svc, on in stamp.enable : svc => "${stamp.name_prefix}${svc}" if on
    }
  }
}

output "keycloak" {
  description = "Keycloak (enable_keycloak): its in-cluster URL, the realm's issuer, and the realm's admin console from the host (log in as sam, the superadmin)"
  value = var.enable_keycloak ? {
    url           = local.keycloak_hostname
    issuer        = module.realm[0].issuer_url
    admin_console = "http://localhost:${var.keycloak_node_port}/admin/${module.realm[0].realm}/console"
    admin_client  = module.keycloak[0].admin_client_id
  } : null
}

output "group_role_urls" {
  description = "Per data group, the Postgres URL of its nb_<tenant>__<group> role (verify-tenants.sh connects with one)"
  value       = { for g, c in module.group_roles.credentials : g => c.url }
  sensitive   = true
}
