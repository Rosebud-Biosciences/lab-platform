# ------------------------------------------------------------------------------
# EKS BLUEPRINTS ADDONS
#
# Addons deploy in two phases to handle webhook dependencies:
#   Phase 1 (core): AWS LB Controller, EKS managed addons, storage, metrics
#   Phase 2:        Karpenter, autoscalers, monitoring, Argo (depends on Phase 1)
# ------------------------------------------------------------------------------

# v6 of the IAM module folded the EKS-specific submodule into
# iam-role-for-service-accounts (the one the workloads module already uses);
# `name` + use_name_prefix is the old role_name_prefix, the output is `arn`.
# Moving an existing cluster onto this recreates the role (new addresses, new
# name); the EBS CSI add-on picks up the new ARN in the same apply.
module "ebs_csi_driver_irsa" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version               = "~> 6.8"
  name                  = format("%s-%s", local.cluster_name, "ebs-csi-driver-")
  use_name_prefix       = true
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

# ------------------------------------------------------------------------------
# PHASE 1: CORE ADDONS
# ------------------------------------------------------------------------------
# Every chart_version / addon_version is pinned explicitly. Left unset, the
# module resolves "most recent", so an upstream release becomes an unreviewed
# upgrade on the next plan. Bump deliberately.
module "eks_blueprints_addons_core" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.24.3"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  eks_addons = {
    aws-ebs-csi-driver = {
      addon_version            = "v1.63.1-eksbuild.1"
      service_account_role_arn = module.ebs_csi_driver_irsa.arn
    }
    coredns = merge(
      {
        addon_version = "v1.14.3-eksbuild.3"
        preserve      = true
      },
      # Tailnet names (a tailnet-only issuer) resolve for pods too (tailscale.tf).
      local.tailscale_dnsconfig ? { configuration_values = jsonencode({ corefile = local.coredns_corefile }) } : {},
    )
  }

  enable_aws_load_balancer_controller = var.enable_aws_load_balancer_controller
  aws_load_balancer_controller = {
    atomic        = true
    chart_version = "1.7.1"
    # Its webhook checks every Service created after it registers, and phase 2
    # and the releases below create Services: phase 1 is done only once the
    # controller's pods are serving it.
    wait    = true
    timeout = "600"
    # Given, not discovered: the nodes allow one metadata hop (the EKS
    # module's default), which a pod cannot reach, and the controller exits
    # when it cannot introspect its VPC.
    values = [yamlencode({ vpcId = var.vpc_id, region = var.region })]
  }

  enable_cluster_proportional_autoscaler = true
  cluster_proportional_autoscaler = {
    atomic        = true
    chart_version = "1.1.0"
    timeout       = "300"
    values = [templatefile("${path.module}/helm-defaults/coredns-autoscaler/values.yaml", {
      target = "deployment/coredns"
    })]
    description = "Cluster Proportional Autoscaler for CoreDNS Service"
  }

  enable_metrics_server = var.enable_metrics_server
  metrics_server = {
    atomic        = true
    chart_version = "3.12.0"
    timeout       = "300"
    values        = [templatefile("${path.module}/helm-defaults/metrics-server/values.yaml", {})]
  }

  helm_releases = {
    storageclass = {
      atomic      = true
      name        = "storageclass"
      description = "A Helm chart for storage configurations"
      chart       = "${path.module}/helm-defaults/storageclass"
    }
  }

  # Opt out of the module's usage telemetry (an empty CloudFormation stack).
  observability_tag = null

  tags = local.tags
}

# ------------------------------------------------------------------------------
# PHASE 2: WORKLOAD ADDONS (Karpenter, autoscalers, monitoring, Argo)
# ------------------------------------------------------------------------------
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.24.3"

  cluster_name              = module.eks.cluster_name
  cluster_endpoint          = module.eks.cluster_endpoint
  cluster_version           = module.eks.cluster_version
  oidc_provider_arn         = module.eks.oidc_provider_arn
  create_delay_dependencies = [terraform_data.phase_1_ready.input]

  eks_addons = {}

  enable_cluster_autoscaler = var.enable_cluster_autoscaler
  cluster_autoscaler = {
    atomic      = true
    timeout     = "300"
    create_role = true
    values = [templatefile("${path.module}/helm-defaults/cluster-autoscaler/values.yaml", {
      aws_region     = var.region,
      eks_cluster_id = module.eks.cluster_name
    })]
  }

  # Karpenter (requires the LB Controller webhook to be ready). CRDs are managed
  # separately via helm_release.karpenter_crd.
  enable_karpenter                  = var.enable_karpenter
  karpenter_enable_spot_termination = var.enable_karpenter
  karpenter = {
    atomic        = true
    chart_version = var.karpenter_version
    timeout       = "300"
  }

  enable_argo_events = var.enable_argo_events
  argo_events = {
    atomic        = true
    name          = "argo-events"
    namespace     = "argo-events"
    repository    = "https://argoproj.github.io/argo-helm"
    chart_version = "2.4.3"
    # Unused by the template; the reference orders this release after phase 1.
    values = [templatefile("${path.module}/helm-defaults/argo/argo-events-values.yaml", { phase_1_ready = terraform_data.phase_1_ready.input })]
  }

  enable_kube_prometheus_stack = var.enable_kube_prometheus
  kube_prometheus_stack = {
    atomic = true
    values = concat(
      # Unused by the template; the reference orders this release after phase 1.
      [templatefile("${path.module}/helm-defaults/kube-prometheus-stack/values.yaml", { phase_1_ready = terraform_data.phase_1_ready.input })],
      var.kube_prometheus_helm_values_override != "" ? [var.kube_prometheus_helm_values_override] : []
    )
    chart_version = "86.2.1"
    set_sensitive = var.enable_kube_prometheus ? [
      {
        name  = "grafana.adminPassword"
        value = data.aws_secretsmanager_secret_version.admin_password_version[0].secret_string
      }
    ] : []
  }

  # external-dns: public hostnames follow the Ingress. modules/workloads stamps
  # external-dns.alpha.kubernetes.io/hostname on its public Ingresses (webapp,
  # JupyterHub); this publishes the matching Route53 records, scoped to the
  # listed zones. upsert-only never deletes a record it did not create;
  # txtOwnerId keeps two clusters sharing a zone from fighting over names.
  enable_external_dns            = var.enable_external_dns
  external_dns_route53_zone_arns = var.external_dns_route53_zone_arns
  external_dns = {
    atomic        = true
    chart_version = "1.22.0"
    values = [yamlencode({
      policy        = "upsert-only"
      txtOwnerId    = module.eks.cluster_name
      domainFilters = var.external_dns_domain_filters
      sources       = ["ingress"]
    })]
  }

  enable_aws_for_fluentbit = var.enable_aws_fluentbit
  aws_for_fluentbit_cw_log_group = {
    use_name_prefix   = false
    name              = "/${local.cluster_name}/aws-fluentbit-logs"
    retention_in_days = 30
  }
  aws_for_fluentbit = {
    atomic        = true
    chart_version = "0.1.32"
    values = [templatefile("${path.module}/helm-defaults/aws-for-fluentbit/values.yaml", {
      region               = var.region,
      cloudwatch_log_group = "/${local.cluster_name}/aws-fluentbit-logs"
      cluster_name         = module.eks.cluster_name
    })]
  }

  observability_tag = null

  tags = local.tags
}

# Phase 2 must wait for phase 1 (the LB Controller's webhook admits every
# Service a chart creates) and for Karpenter's CRDs. It does so by referencing
# this node, through create_delay_dependencies (the module's own sleep, which
# every addon's IAM role and cluster settings pass through) and through the
# values of the addons that reference nothing else. A module depends_on would
# order the same, but it makes tofu resolve all of phase 1 transitively for
# each data source in phase 2: about 6 s of every plan, apply and destroy.
resource "terraform_data" "phase_1_ready" {
  input = "phase 1 ready"

  depends_on = [
    module.eks_blueprints_addons_core,
    helm_release.karpenter_crd,
  ]
}

# ------------------------------------------------------------------------------
# KARPENTER CRDS (managed separately; the main chart's bundled CRDs are
# install-only and never upgraded by Helm). Kept at the controller version.
# ------------------------------------------------------------------------------
resource "helm_release" "karpenter_crd" {
  count = var.enable_karpenter ? 1 : 0

  namespace        = "karpenter"
  create_namespace = true
  name             = "karpenter-crd"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter-crd"
  atomic           = true
  version          = var.karpenter_version
}

# Access entry so Karpenter-launched nodes can join the cluster.
resource "aws_eks_access_entry" "karpenter_node" {
  count = var.enable_karpenter ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = module.eks_blueprints_addons.karpenter.node_iam_role_arn
  type          = "EC2_LINUX"

  tags = local.tags
}

# NOTE: Karpenter NodePools/EC2NodeClasses are owned by the `workloads` module
# (per workload environment, name-prefixed) against this platform's Karpenter
# controller + node IAM role (exposed via the karpenter_node_iam_role_* outputs).

# ------------------------------------------------------------------------------
# GRAFANA ADMIN CREDENTIALS (only when monitoring is enabled)
# ------------------------------------------------------------------------------
data "aws_secretsmanager_secret_version" "admin_password_version" {
  count      = var.enable_kube_prometheus ? 1 : 0
  secret_id  = aws_secretsmanager_secret.grafana[0].id
  depends_on = [aws_secretsmanager_secret_version.grafana]
}

resource "random_password" "grafana" {
  count            = var.enable_kube_prometheus ? 1 : 0
  length           = 16
  special          = true
  override_special = "@_"
}

#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "grafana" {
  #checkov:skip=CKV2_AWS_57:a generated Grafana admin password with no rotation function; rotate by tainting the version
  count                   = var.enable_kube_prometheus ? 1 : 0
  name_prefix             = "${local.cluster_name}-grafana-"
  recovery_window_in_days = 0 # ephemeral: force delete on destroy
}

resource "aws_secretsmanager_secret_version" "grafana" {
  count         = var.enable_kube_prometheus ? 1 : 0
  secret_id     = aws_secretsmanager_secret.grafana[0].id
  secret_string = random_password.grafana[0].result
}

# ------------------------------------------------------------------------------
# DEVICE PLUGINS / OPERATORS (only need the Phase-1 core stack ready)
# ------------------------------------------------------------------------------

# Neuron Device Plugin (Inferentia/Trainium). OCI chart, so `repository` is unset.
resource "helm_release" "aws_neuron_device_plugin" {
  count = var.enable_neuron_support ? 1 : 0

  name             = "neuron-helm-chart"
  chart            = "oci://public.ecr.aws/neuron/neuron-helm-chart"
  atomic           = true
  version          = "1.1.1"
  namespace        = "kube-system"
  create_namespace = false
  timeout          = 300

  depends_on = [module.eks_blueprints_addons_core]
}

resource "helm_release" "nvidia_gpu_operator" {
  count = var.enable_gpu_support ? 1 : 0

  name             = "nvidia-gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  atomic           = true
  version          = "v25.3.0"
  namespace        = "gpu-operator"
  create_namespace = true
  timeout          = 300

  values = [templatefile("${path.module}/helm-defaults/nvidia-gpu-operator/values.yaml", {})]

  depends_on = [module.eks_blueprints_addons_core]
}

resource "helm_release" "kubecost" {
  count = var.enable_kubecost ? 1 : 0

  name             = "kubecost"
  repository       = "oci://public.ecr.aws/kubecost"
  chart            = "cost-analyzer"
  atomic           = true
  version          = "1.103.2"
  namespace        = "kubecost"
  create_namespace = true
  timeout          = 300

  values = [templatefile("${path.module}/helm-defaults/kubecost/values.yaml", {})]

  depends_on = [module.eks_blueprints_addons_core]
}

resource "helm_release" "kuberay_operator" {
  count = var.enable_ray ? 1 : 0

  name             = "kuberay-operator"
  repository       = "https://ray-project.github.io/kuberay-helm/"
  chart            = "kuberay-operator"
  atomic           = true
  version          = var.kuberay_operator_version
  namespace        = "kuberay-operator"
  create_namespace = true
  timeout          = 300

  depends_on = [module.eks_blueprints_addons_core]
}
