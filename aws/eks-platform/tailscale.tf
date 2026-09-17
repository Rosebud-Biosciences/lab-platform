# ------------------------------------------------------------------------------
# TAILSCALE OPERATOR (optional platform singleton)
#
# Installs the cluster-wide Tailscale operator + "tailscale" IngressClass. The
# per-workload Ingresses that expose UIs at stable MagicDNS names live in the
# `workloads` module. Access control is enforced tailnet-side (ACL grants to the
# proxy tag), independent of the EKS security groups.
#
# Prerequisites (Tailscale admin console): an OAuth client with devices:core +
# auth_keys scopes tagged tag:k8s-operator, plus MagicDNS + HTTPS certificates.
# ------------------------------------------------------------------------------

locals {
  enable_tailscale_operator = var.enable_tailscale_operator && var.tailscale_oauth_client_id != ""
}

resource "kubernetes_namespace_v1" "tailscale" {
  count = local.enable_tailscale_operator ? 1 : 0

  metadata {
    name = "tailscale"
  }
}

resource "helm_release" "tailscale_operator" {
  count = local.enable_tailscale_operator ? 1 : 0

  namespace  = kubernetes_namespace_v1.tailscale[0].metadata[0].name
  name       = "tailscale-operator"
  repository = "https://pkgs.tailscale.com/helmcharts"
  chart      = "tailscale-operator"
  version    = var.tailscale_operator_chart_version
  timeout    = 600

  # helm provider 3: set/set_sensitive are list attributes, not repeated blocks.
  set = [
    {
      name  = "operatorConfig.hostname"
      value = "${var.environment}-eks-operator"
    },
    # Only Ingress/egress proxying is needed, not kubectl-over-tailnet; disabling
    # the API-server proxy keeps the operator's required scopes minimal.
    {
      name  = "apiServerProxyConfig.mode"
      value = "false"
    },
  ]

  set_sensitive = [
    {
      name  = "oauth.clientId"
      value = var.tailscale_oauth_client_id
    },
    {
      name  = "oauth.clientSecret"
      value = var.tailscale_oauth_client_secret
    },
  ]

  depends_on = [
    module.eks_blueprints_addons,
  ]
}
