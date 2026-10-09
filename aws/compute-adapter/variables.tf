variable "cluster_name" {
  description = "Name of the EKS cluster (Karpenter discovery tags, resource names)"
  type        = string
}

variable "name_prefix" {
  description = "Same name_prefix as the modules/workloads instance this serves (NodePools, EFS, WAF names are prefixed with it)"
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment name, used in the EFS filesystem name"
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Tags applied to every AWS resource"
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# JupyterHub shared storage: an EFS filesystem
# ------------------------------------------------------------------------------

variable "enable_jupyterhub" {
  description = "Create the EFS filesystem (+ security group and mount targets) behind JupyterHub's shared volume"
  type        = bool
  default     = false
}

variable "jupyterhub_efs_prevent_destroy" {
  description = <<-EOT
    Protect the JupyterHub EFS filesystem (user home directories) from
    `tofu destroy` via lifecycle.prevent_destroy (dynamic; OpenTofu >= 1.12).
    Leave true for durable environments -- destroys then fail until this is
    first flipped off, an intentional two-step. Set false for
    previews/ephemeral stamps so they can tear down.
  EOT
  type        = bool
  default     = true
}

variable "jupyterhub_storage_size" {
  description = "Nominal claim size passed through to workloads (EFS is elastic; this only sizes the PersistentVolume object)"
  type        = string
  default     = "100Gi"
}

variable "vpc_id" {
  description = "VPC ID (required for the EFS security group when enable_jupyterhub)"
  type        = string
  default     = ""
}

variable "private_subnets" {
  description = "Private subnet IDs (EFS mount targets)"
  type        = list(string)
  default     = []
}

variable "private_subnets_cidr_blocks" {
  description = "Private subnet CIDR blocks, same order as private_subnets (used to place EFS mount targets in the pod CIDR)"
  type        = list(string)
  default     = []
}

variable "efs_subnet_cidr_octet_prefix" {
  description = "First-octet prefix selecting which private subnets host the EFS mount targets"
  type        = string
  default     = "100."
}

variable "vpc_secondary_cidr_blocks" {
  description = "Secondary VPC CIDR blocks allowed to reach the EFS (NFS 2049)"
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------------------------
# Public edge: ALB + ACM (+ WAF) annotations for the public Ingresses
# ------------------------------------------------------------------------------

variable "webapp_app_name" {
  description = "Same webapp_app_name as the workloads instance (WAF and log-group names)"
  type        = string
  default     = "webapp"
}

variable "enable_webapp_public_ingress" {
  description = "Emit the ALB annotation set for the public webapp Ingress (and, with enable_webapp_waf, create the WAF ACL)"
  type        = bool
  default     = false
}

variable "webapp_acm_certificate_arn" {
  description = "ACM certificate ARN for the webapp ALB HTTPS listener. Required when enable_webapp_public_ingress is true."
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_webapp_public_ingress || var.webapp_acm_certificate_arn != ""
    error_message = "webapp_acm_certificate_arn is required when enable_webapp_public_ingress is true."
  }
}

variable "webapp_health_check_path" {
  description = "ALB target-group health check path (same as workloads' webapp_health_check_path)"
  type        = string
  default     = "/"
}

variable "webapp_session_affinity_seconds" {
  description = "Target-group cookie stickiness duration (0 disables); pair with workloads' webapp_session_affinity_seconds"
  type        = number
  default     = 0
}

variable "enable_webapp_waf" {
  description = "Attach a WAFv2 web ACL (AWS managed common rules + a per-IP rate limit) to the public webapp ALB"
  type        = bool
  default     = false
}

variable "webapp_waf_rate_limit" {
  description = "WAF rate-based rule limit: max requests per 5-minute window from a single IP before it is blocked"
  type        = number
  default     = 2000
}

variable "webapp_waf_log_retention_days" {
  description = "Retention of the WAF request logs (CloudWatch). A year by default so an incident can be traced back; shorten for a high-traffic public site where the log volume costs more than the history is worth."
  type        = number
  default     = 365
}

variable "jupyterhub_ingress_scheme" {
  description = "ALB scheme for the JupyterHub Ingress annotations ('internal' or 'internet-facing')"
  type        = string
  default     = "internal"

  validation {
    condition     = contains(["internal", "internet-facing"], var.jupyterhub_ingress_scheme)
    error_message = "jupyterhub_ingress_scheme must be 'internal' or 'internet-facing'."
  }
}

variable "jupyterhub_acm_certificate_arn" {
  description = "ACM certificate for the JupyterHub ALB. Empty serves plain HTTP on the (internal) ALB, as before."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# Karpenter NodePools (created per workload environment, name-prefixed)
# ------------------------------------------------------------------------------

variable "vpc_name" {
  description = "VPC name used by Karpenter EC2NodeClasses for subnet/SG discovery (required when karpenter_node_pools is non-empty)"
  type        = string
  default     = ""
}

variable "karpenter_node_iam_role_name" {
  description = "Name of the Karpenter node IAM role (EC2NodeClass role). Empty disables NodePool creation."
  type        = string
  default     = ""
}

variable "node_pools_namespace" {
  description = "Namespace holding the NodePool Helm releases (their records; the NodePools themselves are cluster-scoped). A preview passes one of its own (modules/workloads' webapp_namespace), so its deploy identity writes nothing in Karpenter's."
  type        = string
  default     = "karpenter"
}

variable "karpenter_node_pools" {
  description = "Map of Karpenter NodePool configurations (created only if karpenter_node_iam_role_name is set). Keys are referenced by node_pool_roles."
  type = map(object({
    name                   = optional(string)
    instance_sizes         = optional(list(string), ["large", "xlarge", "2xlarge", "4xlarge", "8xlarge"])
    instance_families      = optional(list(string), ["t3a", "c5", "m5", "r5", "r6g"])
    instance_architectures = optional(list(string), ["amd64"])
    capacity_types         = optional(list(string), ["spot", "on-demand"])
    ami_family             = optional(string, "AL2023")
    labels                 = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
    limits = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for pool in values(var.karpenter_node_pools) : contains(["AL2", "AL2023", "Bottlerocket"], pool.ami_family)
    ])
    error_message = "ami_family must be one of: AL2, AL2023, Bottlerocket."
  }
}

variable "node_pool_roles" {
  description = <<-EOT
    Which workloads pod roles land on which NodePool, e.g.
    { default = ["webapp", "dagster", "mlflow"], gpu = ["ray_worker"] }.
    Keys are karpenter_node_pools keys; values are workloads' scheduling
    roles (webapp, dagster, mlflow, jupyterhub, jupyterhub_singleuser,
    ray_head, ray_worker). Each listed role gets a
    karpenter.sh/nodepool nodeSelector and tolerations for the pool's
    taints. Roles not listed schedule anywhere.
  EOT
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for pool in keys(var.node_pool_roles) : contains(keys(var.karpenter_node_pools), pool)])
    error_message = "every node_pool_roles key must be a karpenter_node_pools key."
  }
}
