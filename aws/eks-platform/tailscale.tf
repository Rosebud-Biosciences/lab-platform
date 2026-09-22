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

# ------------------------------------------------------------------------------
# Tailnet names for pods (enable_tailscale_dnsconfig)
#
# A tailnet-only issuer (Dex or Keycloak behind a Tailscale Ingress) is
# https://<name>.<tailnet>.ts.net in every token, so pods must reach that URL
# too. The operator's DNSConfig runs a nameserver answering <name>.<tailnet>.ts.net
# with the in-cluster address of the operator's proxies; CoreDNS forwards the
# zone to it. The nameserver gets a Service at a fixed ClusterIP of the
# caller's choosing, so CoreDNS's configuration does not wait on the operator.
# ------------------------------------------------------------------------------

locals {
  tailscale_dnsconfig = var.enable_tailscale_dnsconfig && local.enable_tailscale_operator

  # EKS's default Corefile plus the stub zone.
  coredns_corefile = <<-EOT
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
    ${var.tailscale_dns_zone}:53 {
        errors
        cache 30
        forward . ${var.tailscale_nameserver_cluster_ip}
    }
  EOT
}

resource "kubectl_manifest" "tailscale_dnsconfig" {
  count = local.tailscale_dnsconfig ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "tailscale.com/v1alpha1"
    kind       = "DNSConfig"
    metadata   = { name = "ts-dns" }
    spec       = { nameserver = {} }
  })

  depends_on = [helm_release.tailscale_operator]
}

resource "kubernetes_service_v1" "tailscale_nameserver" {
  count = local.tailscale_dnsconfig ? 1 : 0

  metadata {
    name      = "tailnet-dns"
    namespace = kubernetes_namespace_v1.tailscale[0].metadata[0].name
  }

  spec {
    cluster_ip = var.tailscale_nameserver_cluster_ip
    # The operator's nameserver Deployment for the DNSConfig.
    selector = { app = "nameserver" }

    port {
      name        = "dns-udp"
      protocol    = "UDP"
      port        = 53
      target_port = 1053
    }
    port {
      name        = "dns-tcp"
      protocol    = "TCP"
      port        = 53
      target_port = 1053
    }
  }

  lifecycle {
    precondition {
      condition     = can(cidrhost("${var.tailscale_nameserver_cluster_ip}/32", 0))
      error_message = "enable_tailscale_dnsconfig needs tailscale_nameserver_cluster_ip: a free address in the cluster's service CIDR."
    }
  }

  depends_on = [kubectl_manifest.tailscale_dnsconfig]
}
