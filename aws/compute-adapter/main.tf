locals {
  prefix          = var.name_prefix
  iam_desc_suffix = local.prefix != "" ? " (${local.prefix})" : ""
}

# ------------------------------------------------------------------------------
# JupyterHub shared volume: EFS
#
# This filesystem holds every user's home directory and the shared directory.
# OpenTofu 1.12's dynamic prevent_destroy guards it directly: durable
# environments stay protected by default while previews can tear down, and
# flipping the flag is a plan-time guard change. With protection on,
# disabling JupyterHub (or `tofu destroy`) fails until the caller first
# disarms the flag -- an intentional two-step.
# ------------------------------------------------------------------------------

locals {
  efs_name = "jhub-shared-${var.environment}${local.prefix != "" ? "-${trimsuffix(local.prefix, "-")}" : ""}"

  efs_subnet_ids = var.enable_jupyterhub ? compact([
    for subnet_id, cidr_block in zipmap(var.private_subnets, var.private_subnets_cidr_blocks) :
    substr(cidr_block, 0, length(var.efs_subnet_cidr_octet_prefix)) == var.efs_subnet_cidr_octet_prefix ? subnet_id : null
  ]) : []

  jupyterhub_efs = one(aws_efs_file_system.jupyterhub[*])
}

resource "aws_efs_file_system" "jupyterhub" {
  count     = var.enable_jupyterhub ? 1 : 0
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
    prevent_destroy = var.jupyterhub_efs_prevent_destroy
  }
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

# ------------------------------------------------------------------------------
# Public edge annotations (AWS Load Balancer Controller)
# ------------------------------------------------------------------------------

locals {
  webapp_waf_enabled = var.enable_webapp_public_ingress && var.enable_webapp_waf

  webapp_public_ingress_annotations = var.enable_webapp_public_ingress ? merge(
    {
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/listen-ports"     = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      "alb.ingress.kubernetes.io/ssl-redirect"     = "443"
      "alb.ingress.kubernetes.io/certificate-arn"  = var.webapp_acm_certificate_arn
      "alb.ingress.kubernetes.io/healthcheck-path" = var.webapp_health_check_path
    },
    # Optional target-group stickiness for stateful single-pod sessions.
    var.webapp_session_affinity_seconds > 0 ? {
      "alb.ingress.kubernetes.io/target-group-attributes" = join(",", [
        "stickiness.enabled=true",
        "stickiness.type=lb_cookie",
        "stickiness.lb_cookie.duration_seconds=${var.webapp_session_affinity_seconds}",
      ])
    } : {},
    local.webapp_waf_enabled ? {
      "alb.ingress.kubernetes.io/wafv2-acl-arn" = aws_wafv2_web_acl.webapp[0].arn
    } : {}
  ) : {}

  jupyterhub_public_ingress_annotations = merge(
    {
      "alb.ingress.kubernetes.io/scheme"      = var.jupyterhub_ingress_scheme
      "alb.ingress.kubernetes.io/target-type" = "ip"
    },
    var.jupyterhub_acm_certificate_arn != "" ? {
      "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
      "alb.ingress.kubernetes.io/certificate-arn" = var.jupyterhub_acm_certificate_arn
    } : {}
  )
}

# ------------------------------------------------------------------------------
# WAFv2 (optional): AWS managed common rules + a per-IP rate limit
# ------------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "webapp" {
  count = local.webapp_waf_enabled ? 1 : 0

  name        = "${local.prefix}${var.webapp_app_name}-public"
  description = "Baseline protection for the public ${var.webapp_app_name} ALB${local.iam_desc_suffix}."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-common-rules"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}${var.webapp_app_name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # Known bad inputs: the Log4j (CVE-2021-44228) lookups and friends. Cheap,
  # and the rule set the checkov WAF baseline (CKV_AWS_192) expects.
  rule {
    name     = "aws-known-bad-inputs"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}${var.webapp_app_name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "per-ip-rate-limit"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.webapp_waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}${var.webapp_app_name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.prefix}${var.webapp_app_name}-public"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# WAF request logs: the audit trail for what the rules above blocked and why.
# The log group name must start with aws-waf-logs- for WAF to accept it.
# Sampled requests in the console show a slice; this keeps every request for
# webapp_waf_log_retention_days.
resource "aws_cloudwatch_log_group" "webapp_waf" {
  count = local.webapp_waf_enabled ? 1 : 0

  # CloudWatch encrypts log data at rest with an AWS-managed key; WAF request
  # logs carry request metadata, not secrets, and a customer-managed key adds a
  # key policy that can lock the WAF out of its own log group.
  #checkov:skip=CKV_AWS_158:AWS-managed encryption is sufficient for WAF request metadata
  name              = "aws-waf-logs-${local.prefix}${var.webapp_app_name}-public"
  retention_in_days = var.webapp_waf_log_retention_days
  tags              = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "webapp" {
  count = local.webapp_waf_enabled ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.webapp[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.webapp_waf[0].arn]
}

# ------------------------------------------------------------------------------
# Karpenter NodePools (per workload env; names prefixed so previews get their
# own pools that scale to zero and are torn down on destroy)
# ------------------------------------------------------------------------------

locals {
  create_pools = var.karpenter_node_iam_role_name != "" ? var.karpenter_node_pools : {}

  pool_name = { for key, pool in var.karpenter_node_pools : key => "${local.prefix}${coalesce(pool.name, key)}" }

  # The scheduling contract: for every role listed under a pool, select that
  # pool and tolerate its taints.
  scheduling = merge([
    for pool_key, roles in var.node_pool_roles : {
      for role in roles : role => {
        node_selector = { "karpenter.sh/nodepool" = local.pool_name[pool_key] }
        tolerations = [
          for t in var.karpenter_node_pools[pool_key].taints : merge(
            { key = t.key, effect = t.effect },
            t.value != null ? { operator = "Equal", value = t.value } : { operator = "Exists" },
          )
        ]
      }
    }
  ]...)
}

resource "helm_release" "karpenter_node_pools" {
  for_each = local.create_pools

  namespace        = "karpenter"
  create_namespace = false
  name             = "karpenter-resources-${local.prefix}${each.key}"
  chart            = "${path.module}/charts/karpenter-resources"
  atomic           = true

  values = [
    yamlencode({
      name                  = local.pool_name[each.key]
      clusterName           = var.cluster_name
      vpcName               = var.vpc_name
      nodeRole              = var.karpenter_node_iam_role_name
      instanceSizes         = each.value.instance_sizes
      instanceFamilies      = each.value.instance_families
      instanceArchitectures = each.value.instance_architectures
      capacityTypes         = each.value.capacity_types
      amiFamily             = each.value.ami_family
      labels                = each.value.labels
      taints                = [for t in each.value.taints : { for k, v in t : k => v if v != null }]
      limits                = each.value.limits
    })
  ]
}
