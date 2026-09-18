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
}

module "workloads" {
  source = "../../modules/workloads"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  environment = "local"
  name_prefix = var.name_prefix

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

  enable_ray              = true
  enable_ray_cluster      = true
  ray_head_resources      = { requests = { cpu = "500m", memory = "1Gi" }, limits = { cpu = "1", memory = "2Gi" } }
  ray_worker_resources    = { requests = { cpu = "250m", memory = "512Mi" }, limits = { cpu = "1", memory = "1Gi" } }
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
  mlflow_artifact_root = "s3://mlflow/artifacts"
  mlflow_db_host       = var.postgres_host
  mlflow_db_name       = "mlflow"
  mlflow_db_user       = var.postgres_user
  mlflow_db_password   = var.postgres_password

  enable_jupyterhub         = var.enable_jupyterhub
  jupyterhub_auth_mechanism = "dummy"
  jupyterhub_user_password  = var.jupyterhub_user_password
  jupyterhub_admin_users    = ["admin"]

  # No private ingress: on a laptop, port-forward (README). The Tailscale
  # operator works on kind too if you want the same URLs as prod.
  enable_private_ingress = false
}
