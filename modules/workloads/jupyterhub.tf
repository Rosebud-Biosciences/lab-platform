# ------------------------------------------------------------------------------
# WORKLOADS MODULE - JUPYTERHUB (namespaced by name_prefix)
#
# JupyterHub with a shared ReadWriteMany volume (home directories + a shared
# directory) and single-user servers carrying the identity contract. The
# volume is the jupyterhub_shared_storage contract: a static NFS
# PersistentVolume (EFS from aws/compute-adapter, Filestore, any NFS server)
# or a dynamic RWX PersistentVolumeClaim from a StorageClass. Optional public
# Ingress on the caller's IngressClass.
# ------------------------------------------------------------------------------

locals {
  jupyterhub_home_claim   = "jupyterhub-home"
  jupyterhub_shared_claim = "jupyterhub-shared"

  jupyterhub_ingress_enabled = var.enable_jupyterhub && var.jupyterhub_public_host != ""

  jupyterhub_public_annotations = merge(
    var.jupyterhub_public_host != "" ? { "external-dns.alpha.kubernetes.io/hostname" = var.jupyterhub_public_host } : {},
    var.jupyterhub_public_ingress_annotations,
  )

  # The shared directory volume plus the identity token, in the shape
  # KubeSpawner takes for singleuser.storage.extraVolumes / extraVolumeMounts.
  jupyterhub_extra_volumes = concat(
    [{ name = "jupyterhub-shared", persistentVolumeClaim = { claimName = local.jupyterhub_shared_claim } }],
    local.identity_volumes.jupyterhub,
  )
  jupyterhub_extra_volume_mounts = concat(
    [{ name = "jupyterhub-shared", mountPath = "/home/shared", readOnly = false }],
    local.identity_volume_mounts.jupyterhub,
  )

  # NFS ignores fsGroup for ownership, so the container starts as root and
  # chowns the (freshly created) home sub-path and shared dir to the notebook
  # user before dropping privileges -- the docker-stacks start script does it.
  jupyterhub_singleuser_env = merge(
    local.identity.jupyterhub.env,
    local.service_urls_env,
    {
      CHOWN_HOME      = "yes"
      CHOWN_HOME_OPTS = "-R"
      CHOWN_EXTRA     = "/home/shared"
    },
  )
}

resource "kubernetes_namespace_v1" "jupyterhub" {
  count = var.enable_jupyterhub ? 1 : 0

  metadata {
    name = local.jupyterhub_namespace
  }
}

# ------------------------------------------------------------------------------
# Shared RWX volume: two claims (homes, shared) from one small local chart
#
# This is the only persistent user data in the module. Whatever backs it
# (an EFS filesystem, a Filestore share, an NFS box, a RWX StorageClass) is
# created and guarded by the caller/adapter; here we only bind to it, so
# `tofu destroy` of this module never deletes home directories.
# ------------------------------------------------------------------------------

resource "helm_release" "jupyterhub_shared_volume" {
  for_each = var.enable_jupyterhub ? toset([local.jupyterhub_home_claim, local.jupyterhub_shared_claim]) : toset([])

  name             = each.key
  namespace        = kubernetes_namespace_v1.jupyterhub[0].metadata[0].name
  create_namespace = false
  chart            = "${local.helm_defaults}/shared-volume"

  values = [yamlencode({
    name             = each.key
    size             = var.jupyterhub_shared_storage.size
    storageClassName = var.jupyterhub_shared_storage.storage_class_name
    nfs = var.jupyterhub_shared_storage.nfs_server == null ? null : {
      server = var.jupyterhub_shared_storage.nfs_server
      path   = var.jupyterhub_shared_storage.nfs_path
    }
  })]
}

# ------------------------------------------------------------------------------
# Single-user identity
# ------------------------------------------------------------------------------

resource "kubernetes_service_account_v1" "jupyterhub_single_user" {
  count = var.enable_jupyterhub ? 1 : 0

  metadata {
    name        = local.jupyterhub_single_user_sa
    namespace   = kubernetes_namespace_v1.jupyterhub[0].metadata[0].name
    annotations = local.identity.jupyterhub.service_account_annotations
  }

  automount_service_account_token = true
}

resource "kubernetes_secret_v1" "jupyterhub_identity_env" {
  count = var.enable_jupyterhub ? 1 : 0

  metadata {
    name      = local.identity_secret_name.jupyterhub
    namespace = kubernetes_namespace_v1.jupyterhub[0].metadata[0].name
  }

  data = local.identity_secret_env.jupyterhub
}

# ------------------------------------------------------------------------------
# JupyterHub release
# ------------------------------------------------------------------------------

resource "helm_release" "jupyterhub" {
  count = var.enable_jupyterhub ? 1 : 0

  name             = "jupyterhub"
  repository       = "https://hub.jupyter.org/helm-chart/"
  chart            = "jupyterhub"
  version          = var.jupyterhub_chart_version
  timeout          = 600
  namespace        = kubernetes_namespace_v1.jupyterhub[0].metadata[0].name
  create_namespace = false

  values = concat(
    [templatefile("${local.helm_defaults}/jupyterhub/values-${var.jupyterhub_auth_mechanism}.yaml", {
      password                    = var.jupyterhub_user_password
      singleuser_image            = var.jupyterhub_singleuser_image
      jupyter_single_user_sa_name = kubernetes_service_account_v1.jupyterhub_single_user[0].metadata[0].name
      admin_users                 = jsonencode(var.jupyterhub_admin_users)
      allowed_users               = jsonencode(var.jupyterhub_allowed_users)
      allow_all                   = length(var.jupyterhub_allowed_users) == 0
      # oidc mechanism only; the other templates ignore these. Strings are
      # jsonencode()d so secrets with YAML-special characters stay one scalar.
      oidc_client_id      = jsonencode(var.jupyterhub_oidc_client_id)
      oidc_client_secret  = jsonencode(var.jupyterhub_oidc_client_secret)
      oidc_callback_url   = jsonencode(var.jupyterhub_oidc_callback_url)
      oidc_authorize_url  = jsonencode(var.jupyterhub_oidc_authorize_url)
      oidc_token_url      = jsonencode(var.jupyterhub_oidc_token_url)
      oidc_userdata_url   = jsonencode(var.jupyterhub_oidc_userdata_url)
      oidc_scopes         = jsonencode(var.jupyterhub_oidc_scopes)
      oidc_username_claim = jsonencode(var.jupyterhub_oidc_username_claim)
      oidc_login_service  = jsonencode(var.jupyterhub_oidc_login_service)
      # Storage + identity + scheduling contracts (shared by all three templates).
      home_claim               = local.jupyterhub_home_claim
      extra_volumes            = jsonencode(local.jupyterhub_extra_volumes)
      extra_volume_mounts      = jsonencode(local.jupyterhub_extra_volume_mounts)
      singleuser_env           = jsonencode(local.jupyterhub_singleuser_env)
      identity_env_secret      = kubernetes_secret_v1.jupyterhub_identity_env[0].metadata[0].name
      hub_node_selector        = jsonencode(local.scheduling.jupyterhub.node_selector)
      hub_tolerations          = jsonencode(local.scheduling.jupyterhub.tolerations)
      singleuser_node_selector = jsonencode(local.scheduling.jupyterhub_singleuser.node_selector)
      singleuser_tolerations   = jsonencode(local.scheduling.jupyterhub_singleuser.tolerations)
    })],
    # Caller overrides win (later documents take precedence in Helm).
    var.jupyterhub_extra_values,
  )

  depends_on = [helm_release.jupyterhub_shared_volume, kubernetes_secret_v1.jupyterhub_identity_env]
}

# ------------------------------------------------------------------------------
# Public Ingress (optional)
# ------------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "jupyterhub" {
  count = local.jupyterhub_ingress_enabled ? 1 : 0

  metadata {
    name        = "jupyterhub"
    namespace   = kubernetes_namespace_v1.jupyterhub[0].metadata[0].name
    annotations = local.jupyterhub_public_annotations
  }

  spec {
    ingress_class_name = var.jupyterhub_public_ingress_class_name

    dynamic "tls" {
      for_each = var.jupyterhub_public_tls_secret_name != "" ? [1] : []
      content {
        hosts       = [var.jupyterhub_public_host]
        secret_name = var.jupyterhub_public_tls_secret_name
      }
    }

    rule {
      host = var.jupyterhub_public_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "proxy-public"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  wait_for_load_balancer = var.webapp_public_wait_for_load_balancer

  depends_on = [helm_release.jupyterhub]
}
