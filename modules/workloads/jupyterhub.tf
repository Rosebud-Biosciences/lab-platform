# ------------------------------------------------------------------------------
# WORKLOADS MODULE - JUPYTERHUB (namespaced by name_prefix)
#
# JupyterHub with a shared EFS volume and IRSA-backed single-user servers. Moved
# out of the platform module so it can be toggled per environment and previewed.
# Optional internal/internet-facing ALB ingress + Route53 alias.
# ------------------------------------------------------------------------------

locals {
  jupyterhub_namespace = "${local.prefix}jupyterhub"
  efs_name             = "jhub-shared-${var.environment}${local.prefix != "" ? "-${trimsuffix(local.prefix, "-")}" : ""}"

  jupyterhub_single_user_sa = "${var.cluster_name}-${local.prefix}jupyterhub-single-user"

  efs_subnet_ids = var.enable_jupyterhub ? compact([
    for subnet_id, cidr_block in zipmap(var.private_subnets, var.private_subnets_cidr_blocks) :
    substr(cidr_block, 0, length(var.efs_subnet_cidr_octet_prefix)) == var.efs_subnet_cidr_octet_prefix ? subnet_id : null
  ]) : []

  jupyterhub_ingress_enabled = var.enable_jupyterhub && var.jupyterhub_public_host != ""

  # Whichever of the two guard-variant filesystems exists (see below).
  jupyterhub_efs = one(concat(
    aws_efs_file_system.jupyterhub[*],
    aws_efs_file_system.jupyterhub_ephemeral[*],
  ))
}

resource "kubernetes_namespace_v1" "jupyterhub" {
  count = var.enable_jupyterhub ? 1 : 0

  metadata {
    name = local.jupyterhub_namespace
  }
}

# ------------------------------------------------------------------------------
# Shared EFS volume
#
# This filesystem holds every user's home directory and the shared directory --
# the only persistent user data in the module. lifecycle.prevent_destroy must be
# a literal, so the guard is expressed as two mutually exclusive resources and
# var.jupyterhub_efs_prevent_destroy selects which one exists. Flipping the flag
# on a live deployment REPLACES the filesystem (data loss); it exists so durable
# environments are protected by default while previews can still tear down.
# With protection on, disabling JupyterHub (or `terraform destroy`) fails until
# the caller first disarms the flag -- an intentional two-step.
# ------------------------------------------------------------------------------

resource "aws_efs_file_system" "jupyterhub" {
  count     = var.enable_jupyterhub && var.jupyterhub_efs_prevent_destroy ? 1 : 0
  encrypted = true

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = merge(var.tags, {
    Name = local.efs_name
  })

  lifecycle {
    prevent_destroy = true
  }
}

# Identical filesystem minus the guard, for ephemeral stamps (previews).
resource "aws_efs_file_system" "jupyterhub_ephemeral" {
  count     = var.enable_jupyterhub && !var.jupyterhub_efs_prevent_destroy ? 1 : 0
  encrypted = true

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = merge(var.tags, {
    Name = local.efs_name
  })
}

resource "aws_security_group" "efs" {
  count       = var.enable_jupyterhub ? 1 : 0
  name        = "${var.cluster_name}-${local.prefix}jhub-efs"
  description = "Allow inbound NFS from the pod CIDR"
  vpc_id      = var.vpc_id

  ingress {
    description = "NFS 2049/tcp"
    cidr_blocks = var.vpc_secondary_cidr_blocks
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
  }

  tags = var.tags
}

resource "aws_efs_mount_target" "jupyterhub" {
  count = var.enable_jupyterhub ? length(local.efs_subnet_ids) : 0

  file_system_id  = local.jupyterhub_efs.id
  subnet_id       = local.efs_subnet_ids[count.index]
  security_groups = [aws_security_group.efs[0].id]
}

# EFS-backed PV/PVC via a small local chart (one release per claim).
resource "helm_release" "efs_persist" {
  for_each = var.enable_jupyterhub ? toset(["efs-persist", "efs-persist-shared"]) : toset([])

  name             = each.key
  namespace        = kubernetes_namespace_v1.jupyterhub[0].metadata[0].name
  create_namespace = false
  chart            = "${local.helm_defaults}/efs"

  values = [yamlencode({
    pv = {
      name    = each.key
      dnsName = local.jupyterhub_efs.dns_name
    }
    pvc = {
      name = each.key
    }
  })]
}

# ------------------------------------------------------------------------------
# Single-user IRSA (read-only S3 by default)
# ------------------------------------------------------------------------------

module "jupyterhub_single_user_irsa" {
  count   = var.enable_jupyterhub ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name            = "${var.cluster_name}-${local.prefix}jhub-single-user-sa"
  use_name_prefix = false

  policies = {
    s3_read = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${local.jupyterhub_namespace}:${local.jupyterhub_single_user_sa}"]
    }
  }
}

resource "kubernetes_service_account_v1" "jupyterhub_single_user" {
  count = var.enable_jupyterhub ? 1 : 0

  metadata {
    name        = local.jupyterhub_single_user_sa
    namespace   = kubernetes_namespace_v1.jupyterhub[0].metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" : module.jupyterhub_single_user_irsa[0].arn }
  }

  automount_service_account_token = true
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
    })],
    # Caller overrides win (later documents take precedence in Helm).
    var.jupyterhub_extra_values,
  )

  depends_on = [helm_release.efs_persist]
}

# ------------------------------------------------------------------------------
# Ingress & DNS (optional)
# ------------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "jupyterhub" {
  count = local.jupyterhub_ingress_enabled ? 1 : 0

  metadata {
    name      = "jupyterhub"
    namespace = kubernetes_namespace_v1.jupyterhub[0].metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/scheme"      = var.jupyterhub_ingress_scheme
      "alb.ingress.kubernetes.io/target-type" = "ip"
    }
  }

  spec {
    ingress_class_name = "alb"

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

  wait_for_load_balancer = true

  depends_on = [helm_release.jupyterhub]
}

data "aws_lb" "jupyterhub" {
  count = local.jupyterhub_ingress_enabled && var.jupyterhub_route53_zone_id != "" ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "ingress.k8s.aws/stack" = "${local.jupyterhub_namespace}/jupyterhub"
  }

  depends_on = [kubernetes_ingress_v1.jupyterhub]
}

resource "aws_route53_record" "jupyterhub" {
  count = local.jupyterhub_ingress_enabled && var.jupyterhub_route53_zone_id != "" ? 1 : 0

  zone_id = var.jupyterhub_route53_zone_id
  name    = var.jupyterhub_public_host
  type    = "A"

  alias {
    name                   = data.aws_lb.jupyterhub[0].dns_name
    zone_id                = data.aws_lb.jupyterhub[0].zone_id
    evaluate_target_health = true
  }
}
