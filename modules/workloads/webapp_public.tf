# ------------------------------------------------------------------------------
# WORKLOADS MODULE - WEBAPP PUBLIC SURFACE (internet-facing ALB + autoscaling)
#
# Gated on enable_webapp_public_ingress (default OFF). When on, adds:
#   - an internet-facing ALB Ingress (target-type ip, ACM TLS, 80->443 redirect)
#   - an HPA (scales with load) and a PodDisruptionBudget (safe rollouts/drains)
#   - an optional Route53 ALIAS at the public host pointing to the ALB
#   - an optional WAFv2 web ACL (managed common rules + a per-IP rate limit)
#
# Requires the AWS Load Balancer Controller (platform module). Set
# webapp_ignore_image_changes = true so a re-apply does not fight the HPA over
# the replica count.
# ------------------------------------------------------------------------------

locals {
  webapp_public_enabled = var.enable_webapp && var.enable_webapp_public_ingress
  webapp_waf_enabled    = local.webapp_public_enabled && var.enable_webapp_waf

  webapp_alb_annotations = merge(
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
  )
}

resource "kubernetes_ingress_v1" "webapp_public" {
  count = local.webapp_public_enabled ? 1 : 0

  metadata {
    name        = "${var.webapp_app_name}-public"
    namespace   = local.webapp_namespace
    annotations = local.webapp_alb_annotations
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = var.webapp_public_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = var.webapp_app_name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  # Block the apply until the ALB reports a hostname, so the Route53 alias below
  # (which reads the ALB back) has a target.
  wait_for_load_balancer = true

  depends_on = [kubernetes_service_v1.webapp]
}

# The ALB the controller created, found by the tags it stamps on it. A data
# lookup lets the Route53 record be a proper ALIAS (an alias needs the ALB's
# canonical zone id, which the Ingress status hostname alone does not carry).
data "aws_lb" "webapp_public" {
  count = local.webapp_public_enabled && var.webapp_route53_zone_id != "" ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "ingress.k8s.aws/stack" = "${local.webapp_namespace}/${var.webapp_app_name}-public"
  }

  depends_on = [kubernetes_ingress_v1.webapp_public]
}

resource "aws_route53_record" "webapp_public" {
  count = local.webapp_public_enabled && var.webapp_route53_zone_id != "" ? 1 : 0

  zone_id = var.webapp_route53_zone_id
  name    = var.webapp_public_host
  type    = "A"

  alias {
    name                   = data.aws_lb.webapp_public[0].dns_name
    zone_id                = data.aws_lb.webapp_public[0].zone_id
    evaluate_target_health = true
  }
}

# ------------------------------------------------------------------------------
# Autoscaling + availability
# ------------------------------------------------------------------------------

resource "kubernetes_horizontal_pod_autoscaler_v2" "webapp" {
  count = local.webapp_public_enabled ? 1 : 0

  metadata {
    name      = var.webapp_app_name
    namespace = local.webapp_namespace
  }

  spec {
    min_replicas = var.webapp_hpa_min_replicas
    max_replicas = var.webapp_hpa_max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = var.webapp_app_name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.webapp_hpa_cpu_target
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment_v1.webapp,
    kubernetes_deployment_v1.webapp_pinned,
  ]
}

resource "kubernetes_pod_disruption_budget_v1" "webapp" {
  count = local.webapp_public_enabled ? 1 : 0

  metadata {
    name      = var.webapp_app_name
    namespace = local.webapp_namespace
  }

  spec {
    min_available = 1
    selector {
      match_labels = local.webapp_labels
    }
  }
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

  rule {
    name     = "per-ip-rate-limit"
    priority = 2

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
