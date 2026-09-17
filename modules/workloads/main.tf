# ------------------------------------------------------------------------------
# SHARED LOCALS: prefixed names, image tags, private hostnames, and the
# normalized contract inputs (identity, scheduling).
# name_prefix = "" reproduces the base names so this module is a drop-in for a
# single-environment deployment; a non-empty prefix isolates a preview.
# ------------------------------------------------------------------------------

locals {
  prefix = var.name_prefix

  # This module owns its own Helm value templates.
  helm_defaults = "${path.module}/helm-defaults"

  webapp_namespace     = "${local.prefix}${var.webapp_app_name}"
  dagster_namespace    = "${local.prefix}dagster"
  mlflow_namespace     = "${local.prefix}mlflow"
  ray_namespace        = "${local.prefix}ray"
  argo_namespace       = "${local.prefix}argo"
  jupyterhub_namespace = "${local.prefix}jupyterhub"

  # ServiceAccount names: the identity contract. A backend adapter trusts
  # exactly <namespace>/<name> for each service, so these are fixed here and
  # published through output.service_accounts.
  webapp_service_account_name = var.webapp_app_name
  dagster_service_account     = "dagster"
  mlflow_service_account_name = "mlflow"
  ray_service_account_name    = "ray-s3-sa"
  argo_service_account_name   = "argo-workflow"
  jupyterhub_single_user_sa   = "jupyterhub-single-user"

  # Helm release names (the chart derives resource/service names from these).
  dagster_release = "${local.prefix}dagster"
  mlflow_release  = "${local.prefix}mlflow"

  # Chart-derived service names used by the private Ingress backends.
  dagster_webserver_service = "${local.dagster_release}-dagster-webserver"
  mlflow_service            = local.mlflow_release

  # Dagster requires Ray. This is an explicit precondition (see the check block)
  # rather than the old silent `enable_dagster && enable_ray`.
  enable_dagster = var.enable_dagster

  ray_image_tag     = var.ray_image_tag != "" ? var.ray_image_tag : var.ray_version
  ray_gpu_image_tag = var.ray_gpu_image_tag != "" ? var.ray_gpu_image_tag : "${var.ray_version}-gpu"

  # Stamp or share: each stateful service is either created here (in-cluster
  # URL, namespaced so previews never hit another environment's) or, with
  # enable_x = false, pointed at another environment's instance through the
  # *_url / *_uri override. Empty when neither. See README "Stamp or share".
  mlflow_tracking_uri   = var.enable_mlflow ? "http://${local.mlflow_service}.${local.mlflow_namespace}.svc.cluster.local:80" : var.mlflow_tracking_uri
  dagster_webserver_url = local.enable_dagster ? "http://${local.dagster_webserver_service}.${local.dagster_namespace}.svc.cluster.local:80" : var.dagster_webserver_url
  argo_server_url       = var.enable_argo_workflows ? "http://${local.argo_server_service}.${local.argo_namespace}.svc.cluster.local:2746" : var.argo_server_url

  # Published to every pod that runs code (webapp, Dagster user code and runs,
  # Ray pipelines via analytics-config, notebooks) so the code finds its
  # services the same way whether they were stamped or shared.
  service_urls_env = {
    for k, v in {
      MLFLOW_TRACKING_URI   = local.mlflow_tracking_uri
      DAGSTER_WEBSERVER_URL = local.dagster_webserver_url
      ARGO_SERVER_URL       = local.argo_server_url
    } : k => v if v != ""
  }

  # Private hostnames (unique per env via the prefix).
  private_dagster_host = "${var.private_ingress_hostname_prefix}dagster"
  private_mlflow_host  = "${var.private_ingress_hostname_prefix}mlflow"
  private_webapp_host  = "${var.private_ingress_hostname_prefix}webapp"
  private_ray_host     = "${var.private_ingress_hostname_prefix}ray"
  private_argo_host    = "${var.private_ingress_hostname_prefix}argo"
}

# ------------------------------------------------------------------------------
# IDENTITY CONTRACT, normalized per service
#
# Every service gets a full identity object even when the caller supplied
# nothing, so the service files can reference local.identity.<svc>.* without
# guards. The projected token becomes a Kubernetes volume + mount pair in
# plain-map form, which the Helm value templates jsonencode() straight into
# `volumes:` / `volumeMounts:` lists (JSON is valid YAML), and the webapp
# Deployment consumes through dynamic blocks.
# ------------------------------------------------------------------------------

locals {
  identity_services = ["webapp", "dagster", "ray", "argo", "mlflow", "jupyterhub"]

  empty_identity = {
    service_account_annotations = {}
    env                         = {}
    projected_token             = null
  }

  identity = {
    for svc in local.identity_services :
    svc => lookup(var.workload_identity, svc, local.empty_identity)
  }

  identity_secret_env = {
    for svc in local.identity_services :
    svc => lookup(var.workload_identity_secret_env, svc, {})
  }

  identity_secret_name = {
    for svc in local.identity_services : svc => "${svc}-identity-env"
  }

  identity_volume_name = "workload-identity-token"

  identity_volumes = {
    for svc, id in local.identity :
    svc => id.projected_token == null ? [] : [{
      name = local.identity_volume_name
      projected = {
        sources = [{
          serviceAccountToken = {
            audience          = id.projected_token.audience
            expirationSeconds = id.projected_token.expiration_seconds
            path              = id.projected_token.file_name
          }
        }]
      }
    }]
  }

  identity_volume_mounts = {
    for svc, id in local.identity :
    svc => id.projected_token == null ? [] : [{
      name      = local.identity_volume_name
      mountPath = id.projected_token.mount_path
      readOnly  = true
    }]
  }

  # Kubernetes EnvVar list form for charts that take lists (ray-cluster,
  # dagster webserver/daemon).
  identity_env_list = {
    for svc, id in local.identity :
    svc => [for k, v in id.env : { name = k, value = v }]
  }
}

# ------------------------------------------------------------------------------
# SCHEDULING CONTRACT, normalized per pod role
# ------------------------------------------------------------------------------

locals {
  scheduling_roles = ["webapp", "dagster", "mlflow", "argo", "jupyterhub", "jupyterhub_singleuser", "ray_head", "ray_worker"]

  empty_scheduling = { node_selector = {}, tolerations = [] }

  scheduling = {
    for role in local.scheduling_roles :
    role => {
      node_selector = lookup(var.scheduling, role, local.empty_scheduling).node_selector
      # Drop null attributes so the rendered toleration is a clean object.
      tolerations = [
        for t in lookup(var.scheduling, role, local.empty_scheduling).tolerations :
        { for k, v in t : k => v if v != null }
      ]
    }
  }
}
