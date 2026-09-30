# ------------------------------------------------------------------------------
# Identity and tenants (enable_keycloak)
#
# Keycloak holds the users and the tenant tree behind Dex; modules/tenancy
# places each tenant: "lab" (internal) shares everything but runs its own Ray;
# "acme" (external) shares only what isolates tenants (webapp, JupyterHub,
# MLflow) and gets its own Ray, Argo and Dagster, with a bucket of its own.
# Six local users exercise every admin level (scripts/verify-tenants.sh):
#
#   sam    /platform-admins            superadmin
#   ann    /lab/authors                member
#   alice  /lab/authors/admins         group admin
#   bob    (none)                      nobody, until alice adds him
#   cara   /acme/research              member of the external tenant
#   dan    /acme/admins                tenant admin
# ------------------------------------------------------------------------------

locals {
  keycloak_hostname = "http://keycloak-http.keycloak.svc.cluster.local"

  kind_users = {
    sam   = ["/platform-admins"]
    ann   = ["/lab/authors"]
    alice = ["/lab/authors/admins"]
    bob   = []
    cara  = ["/acme/research"]
    dan   = ["/acme/admins"]
  }

  # A filtered for-expression: tenants differ in shape, so they cannot unify
  # with {} in a conditional.
  tenants = { for t, v in var.tenants : t => v if var.enable_keycloak }

  # Static keys stand in for each tenant's cloud role (SeaweedFS identities,
  # prereqs.sh): lab is internal and uses the platform's; acme has its own,
  # limited to its bucket.
  tenant_secret_env = {
    lab  = local.s3_secret_env
    acme = { AWS_ACCESS_KEY_ID = var.acme_s3_access_key, AWS_SECRET_ACCESS_KEY = var.acme_s3_secret_key }
  }
}

module "keycloak" {
  source = "../../modules/keycloak"
  count  = var.enable_keycloak ? 1 : 0

  providers = {
    kubernetes = kubernetes
    helm       = helm
  }

  # Browsers (curl pods) and Dex reach it here; tofu reaches it through the
  # NodePort kind maps to localhost (backchannel_dynamic).
  hostname      = local.keycloak_hostname
  proxy_headers = ""
  service_type  = "NodePort"
  node_port     = var.keycloak_node_port
  database = {
    host     = var.postgres_host
    name     = "keycloak"
    username = var.postgres_user
    password = var.postgres_password
  }
  resources = {
    requests = { cpu = "100m", memory = "512Mi" }
    limits   = { memory = "1Gi" }
  }
}

module "realm" {
  source = "../../modules/keycloak-realm"
  count  = var.enable_keycloak ? 1 : 0

  depends_on = [module.keycloak]

  keycloak_base_url = local.keycloak_hostname
  ssl_required      = "none"
  tenants           = module.tenancy.realm_tenants
  superadmins       = ["sam@example.com"]
  dex_redirect_uri  = "${local.dex_issuer}/callback"
  local_users = {
    for name, groups in local.kind_users : name => {
      email      = "${name}@example.com"
      password   = var.kind_users_password
      first_name = title(name)
      last_name  = "Example"
      groups     = groups
    }
  }
}

module "tenancy" {
  source = "../../modules/tenancy"

  tenants          = local.tenants
  platform_prefix  = var.name_prefix
  tenant_identity  = { for t in keys(local.tenants) : t => { env = local.s3_env, secret_env = local.tenant_secret_env[t] } }
  group_secret_env = { for g, c in module.group_roles.credentials : g => { DATABASE_URL = c.url } }
}

# Notebook / tenant-compute roles on the app database (row-level security).
# The group list is computed here rather than taken from tenancy's
# postgres_data_groups: tenancy consumes these roles' credentials.
module "group_roles" {
  source = "../../modules/postgres-group-roles"

  groups     = flatten([for t, v in local.tenants : [for g, gv in v.groups : "/${t}/${g}" if try(gv.data, true)]])
  connection = { host = var.postgres_host, database = "app", sslmode = "disable" }
}

# ------------------------------------------------------------------------------
# One stamp per tenant with isolated services: modules/workloads again, sized
# down, fenced to the tenant, using the platform's MLflow.
# ------------------------------------------------------------------------------

module "tenant_stamp" {
  source   = "../../modules/workloads"
  for_each = module.tenancy.stamps

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  depends_on = [module.dex]

  environment = "local-${each.key}"
  name_prefix = each.value.name_prefix

  auth = {
    mode             = "oidc"
    issuer_url       = module.dex.issuer_url
    dex_namespace    = module.dex.namespace
    superadmin_group = "/platform-admins"
    protect          = { for svc, gate in each.value.protect : svc => gate if each.value.enable[svc] }
    argo_rbac_rules  = each.value.argo_rbac_rules
    cookie_secure    = false
    external_scheme  = "http"
  }
  network_policies = merge(each.value.network_policies, { ingress_namespaces = ["verify"] })

  workload_identity            = { for svc in ["ray", "dagster", "argo"] : svc => { env = each.value.identity.env } }
  workload_identity_secret_env = { for svc in ["ray", "dagster", "argo"] : svc => each.value.identity.secret_env }

  # The platform's MLflow, with the tenant's service account (mlflow-auth-sync
  # fills mlflow-credentials in the stamp's namespaces).
  mlflow_tracking_uri        = "http://${var.name_prefix}mlflow.${var.name_prefix}mlflow.svc.cluster.local:80"
  mlflow_client_credentials  = each.value.mlflow.client_credentials
  mlflow_auth_sync_namespace = each.value.mlflow.sync_namespace

  enable_ray               = each.value.enable.ray
  enable_ray_cluster       = each.value.enable.ray
  ray_head_num_cpus        = 0
  ray_head_start_params    = { "object-store-memory" = "100000000" } # 100 MB: a small head on a laptop
  ray_head_resources       = { requests = { cpu = "50m", memory = "512Mi" }, limits = { cpu = "1", memory = "1536Mi" } }
  ray_worker_resources     = { requests = { cpu = "50m", memory = "512Mi" }, limits = { cpu = "1", memory = "1Gi" } }
  ray_autoscaler_resources = { requests = { cpu = "50m", memory = "256Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
  ray_worker_max_replicas  = 1

  enable_argo_workflows = each.value.enable.argo

  enable_dagster          = each.value.enable.dagster
  dagster_db_host         = var.postgres_host
  dagster_db_name         = "dagster_${each.key}"
  dagster_db_user         = var.postgres_user
  dagster_db_password     = var.postgres_password
  dagster_user_code_image = each.value.dagster_image

  enable_private_ingress = false
}
