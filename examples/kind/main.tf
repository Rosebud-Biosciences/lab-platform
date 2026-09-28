# ------------------------------------------------------------------------------
# KIND EXAMPLE: local compute + local data
#
# The portable workloads module on a kind cluster, with SeaweedFS as the S3 API
# and Postgres as the database. No adapters, no cloud provider: the four
# contract inputs are written by hand here, which is also the template for a
# "metal" backend. Sized to fit a 4-vCPU / 16 GiB GitHub runner; see the README
# for the laptop flow and .github/workflows/kind-smoke.yml for the CI one.
# ------------------------------------------------------------------------------

locals {
  # Static credentials to an S3-compatible store: the identity contract's
  # third mechanism. Every service gets the same endpoint; boto3/fsspec
  # (Dagster, Ray, the app) read AWS_ENDPOINT_URL, MLflow reads
  # MLFLOW_S3_ENDPOINT_URL. The two checksum settings keep the AWS SDKs from
  # sending the flexible checksums (aws-chunked uploads) that only AWS S3
  # itself is guaranteed to accept.
  s3_env = {
    AWS_REGION                       = "us-east-1"
    AWS_ENDPOINT_URL                 = var.s3_endpoint
    MLFLOW_S3_ENDPOINT_URL           = var.s3_endpoint
    AWS_S3_FORCE_PATH_STYLE          = "true"
    AWS_REQUEST_CHECKSUM_CALCULATION = "when_required"
    AWS_RESPONSE_CHECKSUM_VALIDATION = "when_required"
  }
  s3_secret_env = {
    AWS_ACCESS_KEY_ID     = var.s3_access_key
    AWS_SECRET_ACCESS_KEY = var.s3_secret_key
  }

  services = ["webapp", "dagster", "ray", "argo", "mlflow", "jupyterhub"]

  database_url = "postgresql://${var.postgres_user}:${var.postgres_password}@${var.postgres_host}:5432/app"

  dex_issuer = "http://dex.dex.svc.cluster.local:5556/dex"
}

# ------------------------------------------------------------------------------
# Dex: the cluster's OIDC issuer, with two ways to log in and no external IdP:
#   - the password DB: admin@example.com (no groups), password from the hash
#     variable ("password" by default);
#   - the mockCallback connector: a fixed identity in group "authors".
# Together they let scripts/verify.sh prove both a plain login and a group
# gate. The in-cluster Service URL is the issuer because browsers (here:
# curl pods) and the proxies both reach it there.
# ------------------------------------------------------------------------------

module "dex" {
  source = "../../modules/dex"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  issuer_url = local.dex_issuer
  # With Keycloak (tenants.tf) it is Dex's one connector; without it, the
  # password DB and the mock connector.
  enable_password_db = !var.enable_keycloak
  static_passwords = var.enable_keycloak ? [] : [{
    email    = var.dex_admin_email
    hash     = var.dex_admin_password_hash
    username = "admin"
    user_id  = "08a8684b-db88-4b73-90a9-3cd1661f5466"
  }]
  connectors = concat(
    module.realm[*].dex_connector,
    var.enable_keycloak ? [] : [{ type = "mockCallback", id = "mock", name = "Example (mock user, group authors)" }],
  )
  connector_env = var.enable_keycloak ? module.realm[0].dex_connector_env : {}

  # A stand-in for a preview's CI identity: verify.sh acts as "preview-ci"
  # (kubectl --as) and must be able to manage only pr<N>- clients.
  client_admission = { restricted_user_prefixes = ["preview-ci"] }
}

module "workloads" {
  source = "../../modules/workloads"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  # The OAuth2Client CRs need Dex's CRDs, which Dex registers on first start.
  depends_on = [module.dex]

  environment = "local"
  name_prefix = var.name_prefix

  # --- Auth: OIDC against Dex, no network in the loop ---------------------------
  # With Keycloak: gates from the tenancy matrix (tenants.tf), superadmins
  # everywhere, MLflow on its own OIDC with per-experiment permissions.
  # Without: Dagster gated on the mock user's group "authors", MLflow and the
  # Ray dashboard on the two test identities' domains, Argo for authors.
  # No private Ingress here, so the redirect URLs are the in-cluster Service
  # URLs -- which is exactly what verify.sh's curl pod uses.
  auth = {
    mode             = "oidc"
    issuer_url       = module.dex.issuer_url
    dex_namespace    = module.dex.namespace
    superadmin_group = var.enable_keycloak ? "/platform-admins" : ""
    protect = var.enable_keycloak ? {
      dagster = { allowed_groups = module.tenancy.shared.dagster_allowed_groups }
      ray     = { allowed_groups = module.tenancy.shared.ray_allowed_groups }
      } : {
      dagster = { allowed_groups = ["authors"] }
      mlflow  = { allowed_groups = [] }
      ray     = { allowed_groups = [] }
    }
    allowed_email_domains = var.enable_keycloak ? [] : ["example.com", "kilgore.trout"]
    argo_rbac_rules = var.enable_keycloak ? module.tenancy.shared.argo_rbac_rules : {
      authors = { rule = "'authors' in groups", access = "write", precedence = 10 }
    }
    mlflow_mode               = var.enable_keycloak ? "oidc" : "proxy"
    mlflow_groups             = var.enable_keycloak ? module.tenancy.shared.mlflow_groups : []
    mlflow_group_rules        = var.enable_keycloak ? module.tenancy.shared.mlflow_group_rules : []
    jupyterhub_allowed_groups = var.enable_keycloak ? module.tenancy.shared.jupyterhub_allowed_groups : []
    cookie_secure             = false # plain http inside the cluster
    external_scheme           = "http"
  }
  mlflow_service_accounts   = module.tenancy.shared.mlflow_service_accounts
  dagster_code_locations    = module.tenancy.shared.dagster_code_locations
  jupyterhub_group_profiles = var.enable_keycloak ? module.tenancy.shared.jupyterhub_group_profiles : {}

  # The fence: only the "ingress" may reach a login proxy (or an unproxied
  # UI); here verify.sh's probe namespace plays the ingress controller.
  network_policies = { ingress_namespaces = ["verify"] }

  # --- Contract inputs, by hand -------------------------------------------
  workload_identity            = { for svc in local.services : svc => { env = local.s3_env } }
  workload_identity_secret_env = { for svc in local.services : svc => local.s3_secret_env }
  # scheduling: default {} -- one node, everything goes anywhere.
  jupyterhub_shared_storage = { storage_class_name = var.jupyterhub_storage_class, size = "5Gi" }

  # --- Workloads ------------------------------------------------------------
  enable_webapp         = true
  webapp_image          = var.webapp_image
  webapp_container_port = var.webapp_container_port
  webapp_memory_request = "64Mi"
  webapp_memory_limit   = "256Mi"
  database_url          = local.database_url

  enable_ray         = true
  enable_ray_cluster = true
  # Small requests so everything schedules on a 2-vCPU runner (README
  # "Sizing"); the limits let a busy head or worker burst.
  ray_head_resources      = { requests = { cpu = "50m", memory = "512Mi" }, limits = { cpu = "1", memory = "2Gi" } }
  ray_worker_resources    = { requests = { cpu = "50m", memory = "512Mi" }, limits = { cpu = "1", memory = "1Gi" } }
  ray_worker_max_replicas = 1

  enable_dagster      = true
  dagster_db_host     = var.postgres_host
  dagster_db_name     = "dagster"
  dagster_db_user     = var.postgres_user
  dagster_db_password = var.postgres_password
  # Where pipeline code finds its data: the bucket prereqs.sh created.
  dagster_user_code_env = { DATA_ROOT = "s3://data" }

  # Argo per environment with the workflow archive on the local Postgres (no
  # TLS in-cluster); the CRDs came from prereqs.sh.
  enable_argo_workflows        = true
  enable_argo_workflow_archive = true
  argo_db_host                 = var.postgres_host
  argo_db_name                 = "argo"
  argo_db_user                 = var.postgres_user
  argo_db_password             = var.postgres_password
  argo_db_ssl_mode             = "disable"

  enable_mlflow        = true
  mlflow_workers       = 1     # one process is plenty here and keeps the node inside a laptop's memory
  mlflow_job_execution = false # MLflow 3's job runner + Huey consumers: over a GiB, unused here
  mlflow_artifact_root = "s3://mlflow/artifacts"
  mlflow_db_host       = var.postgres_host
  mlflow_db_name       = "mlflow"
  mlflow_db_user       = var.postgres_user
  mlflow_db_password   = var.postgres_password

  enable_jupyterhub = var.enable_jupyterhub
  # OIDC (the auth mode's default) with Keycloak; a shared password without.
  jupyterhub_auth_mechanism = var.enable_keycloak ? null : "dummy"
  jupyterhub_user_password  = var.jupyterhub_user_password
  jupyterhub_admin_users    = ["admin"]

  # No private ingress: on a laptop, port-forward (README). The Tailscale
  # operator works on kind too if you want the same URLs as prod.
  enable_private_ingress = false
}
