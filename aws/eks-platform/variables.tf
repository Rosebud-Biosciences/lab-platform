# ------------------------------------------------------------------------------
# EKS PLATFORM MODULE - INPUT VARIABLES (PLATFORM ONLY)
#
# This module owns the cluster + cluster-wide add-ons (Karpenter controller, LB
# controller, monitoring, GPU/Neuron device plugins, KubeRay + Argo controllers,
# Tailscale operator). Application workloads (webapp, JupyterHub, Dagster,
# MLflow, the Ray namespace/cluster, private Ingresses, and Karpenter NodePools)
# live in the sibling `workloads` module.
# ------------------------------------------------------------------------------

variable "environment" {
  description = "Environment name (e.g. dev, prod), used to derive the cluster name"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the EKS cluster will be deployed"
  type        = string
}

variable "private_subnets" {
  description = "List of private subnet IDs available to the cluster"
  type        = list(string)
}

variable "private_subnets_cidr_blocks" {
  description = "List of private subnet CIDR blocks (same order as private_subnets)"
  type        = list(string)
}

variable "vpc_security_group_id" {
  description = "Security group ID allowed to reach the cluster/nodes from within the VPC (e.g. the Tailscale relay SG for private admin access)"
  type        = string
}

variable "node_subnet_ids" {
  description = <<-EOT
    Explicit subnet IDs to place the data plane (nodes) in. Empty derives them
    from private_subnets, excluding any subnet inside a secondary CIDR (pod IP
    space). Set this explicitly if your secondary CIDR is not 100.x.
  EOT
  type        = list(string)
  default     = []
}

variable "secondary_vpc_cidr_octet_prefix" {
  description = "First-octet prefix of the secondary (pod) CIDR used to exclude those subnets from the data plane when node_subnet_ids is empty"
  type        = string
  default     = "100."
}

# ------------------------------------------------------------------------------
# CLUSTER CONFIGURATION
# ------------------------------------------------------------------------------

variable "cluster_suffix" {
  description = "Optional suffix for the cluster name (e.g. 'pr123' -> 'eks-dev-pr123')"
  type        = string
  default     = ""
}

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster. Hold at 1.35 (or disable cluster-autoscaler) before moving to 1.36: the autoscaler chart has no 1.36 image yet."
  type        = string
  default     = "1.35"
}

variable "vpc_name" {
  description = "VPC name used by Karpenter node templates for subnet discovery. Empty derives 'vpc-{environment}'."
  type        = string
  default     = ""
}

variable "cluster_endpoint_public_access" {
  description = "Whether the EKS cluster endpoint is publicly accessible"
  type        = bool
  default     = false
}

variable "cluster_endpoint_private_access" {
  description = "Whether the EKS cluster endpoint is privately accessible"
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# CLUSTER ACCESS (EKS access entries)
#
# The cluster uses API authentication mode, so who may talk to the Kubernetes
# API is decided by EKS access entries, not the aws-auth ConfigMap. The
# kubernetes/helm/kubectl providers authenticate with `aws eks get-token`, which
# signs as whatever AWS credentials are ambient -- so EVERY identity that will
# run tofu against this cluster (or kubectl) needs an entry, and the entry has
# to be created by an identity that already has one.
# ------------------------------------------------------------------------------

variable "enable_cluster_creator_admin_permissions" {
  description = <<-EOT
    Give the identity that creates the cluster a cluster-admin access entry.
    Leave on for the first apply (otherwise nobody can reach the API to install
    the add-ons); turn off once access_entries carries the identities you
    actually operate from, so a bootstrap credential does not keep standing
    admin. Turning it off removes the creator's entry -- make sure the identity
    running that apply is in access_entries first.
  EOT
  type        = bool
  default     = true
}

variable "access_entries" {
  description = <<-EOT
    Additional EKS access entries, keyed by a stable label. Same shape as the
    upstream terraform-aws-modules/eks input: each entry names a principal and
    zero or more policy associations. Use it for every non-creator identity
    that runs tofu or kubectl here -- an MFA-gated operator role (see
    docs/operator-access.md), a CI role that deploys workloads, an SSO
    permission set. Policy ARNs are the AWS-managed cluster access policies,
    e.g. arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy.
  EOT
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string))
    user_name         = optional(string)
    tags              = optional(map(string), {})
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        type       = string
        namespaces = optional(list(string))
      })
    })), {})
  }))
  default = {}
}

# ------------------------------------------------------------------------------
# CORE NODE GROUP
# ------------------------------------------------------------------------------

variable "core_node_group_instance_types" {
  description = "Instance types for the core managed node group that hosts the add-ons"
  type        = list(string)
  default     = ["t3a.large"]
}

variable "core_node_group_min_size" {
  description = "Minimum number of nodes in the core node group"
  type        = number
  default     = 1
}

variable "core_node_group_max_size" {
  description = "Maximum number of nodes in the core node group"
  type        = number
  default     = 2
}

variable "core_node_group_desired_size" {
  description = "Desired number of nodes in the core node group"
  type        = number
  default     = 2
}

# ------------------------------------------------------------------------------
# FEATURE TOGGLES (platform add-ons / operators)
#
# OSS defaults keep the always-on essentials (Karpenter, LB controller,
# metrics-server) enabled and the optional cost-drivers (monitoring, Kubecost,
# FluentBit) OFF, so a fresh cluster is cheap. Turn them on per environment.
# ------------------------------------------------------------------------------

variable "enable_karpenter" {
  description = "Enable the Karpenter controller + CRDs (NodePools are defined per environment by aws/compute-adapter)"
  type        = bool
  default     = true
}

variable "enable_aws_load_balancer_controller" {
  description = "Enable AWS Load Balancer Controller"
  type        = bool
  default     = true
}

variable "enable_metrics_server" {
  description = "Enable Kubernetes Metrics Server"
  type        = bool
  default     = true
}

variable "enable_cluster_autoscaler" {
  description = "Enable Cluster Autoscaler (leave off when using Karpenter for burst)"
  type        = bool
  default     = false
}

variable "enable_kube_prometheus" {
  description = "Enable the Prometheus + Grafana monitoring stack"
  type        = bool
  default     = false
}

variable "kube_prometheus_helm_values_override" {
  description = "Extra YAML (raw string) deep-merged over the kube-prometheus-stack defaults by Helm (later wins)"
  type        = string
  default     = ""
}

variable "enable_external_dns" {
  description = "Enable external-dns so public hostnames follow the Ingresses modules/workloads creates (it stamps external-dns.alpha.kubernetes.io/hostname). Requires external_dns_route53_zone_arns."
  type        = bool
  default     = false
}

variable "external_dns_route53_zone_arns" {
  description = "Route53 hosted zone ARNs external-dns may write to (its IRSA policy is scoped to these)"
  type        = list(string)
  default     = []

  validation {
    condition     = !var.enable_external_dns || length(var.external_dns_route53_zone_arns) > 0
    error_message = "external_dns_route53_zone_arns is required when enable_external_dns is true."
  }
}

variable "external_dns_domain_filters" {
  description = "Domains external-dns manages records for (e.g. [\"example.com\"]); empty means every zone it can reach"
  type        = list(string)
  default     = []
}

variable "enable_aws_fluentbit" {
  description = "Enable AWS FluentBit -> CloudWatch logging"
  type        = bool
  default     = false
}

variable "enable_kubecost" {
  description = "Enable Kubecost for cost monitoring"
  type        = bool
  default     = false
}

variable "enable_gpu_support" {
  description = "Enable the NVIDIA GPU Operator"
  type        = bool
  default     = false
}

variable "enable_neuron_support" {
  description = "Enable the AWS Neuron device plugin (Inferentia/Trainium)"
  type        = bool
  default     = false
}

variable "enable_ray" {
  description = "Install the KubeRay operator (the Ray namespace/cluster live in the workloads module)"
  type        = bool
  default     = false
}

variable "enable_argo_workflows" {
  description = "Install the Argo Workflows CRDs (cluster-scoped, from the upstream release at argo_workflows_version). The controller, server, UI and optional archive are per environment in modules/workloads (enable_argo_workflows there)."
  type        = bool
  default     = false
}

variable "argo_workflows_version" {
  description = "Argo Workflows release tag the CRDs are taken from. Keep equal to the appVersion of modules/workloads' argo_workflows_chart_version (chart 2.0.6 -> v4.1.3)." # renovate: github-releases argoproj/argo-workflows
  type        = string
  default     = "v4.1.3"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+", var.argo_workflows_version))
    error_message = "argo_workflows_version must be a release tag like v4.1.3."
  }
}

variable "enable_argo_events" {
  description = "Enable Argo Events"
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# CHART / OPERATOR VERSIONS
# ------------------------------------------------------------------------------

variable "karpenter_version" {
  description = "Version of the Karpenter controller and CRD Helm charts"
  type        = string
  default     = "1.13.0"
}

variable "kuberay_operator_version" {
  description = "KubeRay operator Helm chart version"
  type        = string
  default     = "1.6.1"
}

# ------------------------------------------------------------------------------
# TAILSCALE OPERATOR (optional; provides the 'tailscale' IngressClass)
# ------------------------------------------------------------------------------

variable "enable_tailscale_operator" {
  description = "Deploy the Tailscale Kubernetes operator (provides the 'tailscale' IngressClass used by private workload Ingresses)"
  type        = bool
  default     = false
}

variable "tailscale_operator_chart_version" {
  description = <<-EOT
    Pinned tailscale-operator Helm chart version (tracks the Tailscale client
    release train; see https://pkgs.tailscale.com/helmcharts). This one pin is
    the Tailscale version of every container on the tailnet: the operator and
    the Ingress proxies it runs for each private UI. Containers never
    self-update, so bumping it is how Tailscale CVE fixes reach the cluster;
    the operator rolls each proxy to the new image (node identity persists,
    expect a pod-restart blip per UI). See docs/upgrades.md.
  EOT
  type        = string
  default     = "1.102.3"
}

variable "tailscale_oauth_client_id" {
  description = "Tailscale OAuth client ID for the operator (tagged tag:k8s-operator). Required if enable_tailscale_operator is true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "Tailscale OAuth client secret paired with tailscale_oauth_client_id"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
