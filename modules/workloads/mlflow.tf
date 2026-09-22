# ------------------------------------------------------------------------------
# WORKLOADS MODULE - MLFLOW TRACKING SERVER (namespaced by name_prefix)
#
# community-charts/mlflow against an external Postgres, with an S3-compatible
# artifact root (mlflow_artifact_root) reached through the identity contract:
# SA annotations for webhook identity, env for a projected token or an
# alternate endpoint (an S3-compatible store), and the <svc>-identity-env Secret for static keys.
# ------------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "mlflow" {
  count = var.enable_mlflow ? 1 : 0

  metadata {
    name = local.mlflow_namespace
    # NetworkPolicies admit client services by this label (netpol.tf).
    labels = merge({ "lab-platform.io/service" = "mlflow" }, local.tenant_labels)
  }
}

resource "kubernetes_secret_v1" "mlflow_identity_env" {
  count = var.enable_mlflow ? 1 : 0

  metadata {
    name      = local.identity_secret_name.mlflow
    namespace = kubernetes_namespace_v1.mlflow[0].metadata[0].name
  }

  data = local.identity_secret_env.mlflow
}

locals {
  # s3://bucket[/prefix] -> bucket, prefix for the chart's artifactRoot.s3 block.
  mlflow_artifact_bucket = var.mlflow_artifact_root != "" ? regex("^s3://([^/]+)", var.mlflow_artifact_root)[0] : ""
  mlflow_artifact_path   = var.mlflow_artifact_root != "" ? trimprefix(trimprefix(var.mlflow_artifact_root, "s3://${local.mlflow_artifact_bucket}"), "/") : ""

  # MLflow >= 3.5 refuses any Host header it was not told about (DNS-rebinding
  # protection; only localhost and private IPs by default), which is every
  # hostname a tracking server is actually reached at. Allow the names this
  # module gives it -- in-cluster Service, private Ingress, its oauth2-proxy --
  # plus whatever the caller adds. "host:*" also matches a Host with a port.
  mlflow_allowed_hosts = distinct(flatten([
    for h in concat(
      [
        local.mlflow_service,
        "${local.mlflow_service}.${local.mlflow_namespace}",
        "${local.mlflow_service}.${local.mlflow_namespace}.svc",
        "${local.mlflow_service}.${local.mlflow_namespace}.svc.cluster.local",
        "${local.proxy_service_name.mlflow}.${local.mlflow_namespace}.svc.cluster.local",
        "localhost",
        "127.0.0.1",
      ],
      var.private_ingress_dns_suffix != "" ? ["${local.private_mlflow_host}.${var.private_ingress_dns_suffix}"] : [],
      var.mlflow_allowed_hosts,
    ) : [h, "${h}:*"]
  ]))

  mlflow_env = merge(
    local.identity.mlflow.env,
    { MLFLOW_SERVER_ALLOWED_HOSTS = join(",", local.mlflow_allowed_hosts) },
    var.mlflow_job_execution ? {} : { MLFLOW_SERVER_ENABLE_JOB_EXECUTION = "false" },
  )
}

resource "helm_release" "mlflow" {
  count = var.enable_mlflow ? 1 : 0

  namespace  = kubernetes_namespace_v1.mlflow[0].metadata[0].name
  name       = local.mlflow_release
  repository = var.mlflow_repository
  chart      = "mlflow"
  version    = var.mlflow_chart_version
  timeout    = 600

  values = concat([templatefile("${local.helm_defaults}/mlflow/values.yaml", {
    image_repository            = var.mlflow_image.repository
    image_tag                   = var.mlflow_image.tag
    service_account_name        = local.mlflow_service_account_name
    service_account_annotations = jsonencode(local.identity.mlflow.service_account_annotations)
    artifact_bucket             = local.mlflow_artifact_bucket
    artifact_path               = local.mlflow_artifact_path
    db_host                     = var.mlflow_db_host
    db_name                     = var.mlflow_db_name
    db_user                     = jsonencode(var.mlflow_db_user)
    db_password                 = jsonencode(var.mlflow_db_password)
    identity_env                = jsonencode(local.mlflow_env)
    workers                     = var.mlflow_workers
    identity_env_secret         = kubernetes_secret_v1.mlflow_identity_env[0].metadata[0].name
    identity_volumes            = jsonencode(local.identity_volumes.mlflow)
    identity_volume_mounts      = jsonencode(local.identity_volume_mounts.mlflow)
    node_selector               = jsonencode(local.scheduling.mlflow.node_selector)
    tolerations                 = jsonencode(local.scheduling.mlflow.tolerations)
  })], compact([local.mlflow_oidc_values]))
}
