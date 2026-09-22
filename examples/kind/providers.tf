# All three providers read the kubeconfig kind wrote. Any other cluster works
# the same way: point kubeconfig_path / kube_context at it.
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  config_context   = var.kube_context
  load_config_file = true
}

# Keycloak's admin API through the NodePort kind maps to the host, as the
# master realm's admin service account modules/keycloak bootstraps (client
# credentials; initial_login = false lets the first plan run before Keycloak
# exists).
provider "keycloak" {
  url           = "http://localhost:${var.keycloak_node_port}"
  client_id     = var.enable_keycloak ? module.keycloak[0].admin_client_id : "admin-cli"
  client_secret = one(module.keycloak[*].admin_client_secret)
  initial_login = false
}

# The local Postgres through its NodePort (modules/postgres-group-roles).
provider "postgresql" {
  host      = "localhost"
  port      = var.postgres_node_port
  username  = var.postgres_user
  password  = var.postgres_password
  sslmode   = "disable"
  superuser = true
}
