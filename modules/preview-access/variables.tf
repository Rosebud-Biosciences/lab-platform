variable "group" {
  description = "Kubernetes group the preview deploy identity is mapped to (on EKS, its access entry's kubernetes_groups)"
  type        = string
  default     = "lab-platform:preview"
}

variable "namespace_prefix" {
  description = "Prefix of every cluster-scoped name a preview creates -- its namespaces, NodePools and EC2NodeClasses (modules/workloads' and aws/compute-adapter's name_prefix starts with it). No other namespace may start with it: the preview may bind itself admin in any namespace that does."
  type        = string
  default     = "preview-"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*-$", var.namespace_prefix))
    error_message = "namespace_prefix must be a DNS label prefix ending in a dash (e.g. \"preview-\"), so no other name can start with it by accident."
  }
}

variable "karpenter" {
  description = "Let previews manage their own Karpenter NodePools and EC2NodeClasses (aws/compute-adapter)"
  type        = bool
  default     = true
}

variable "dex_namespace" {
  description = "Dex's namespace, where a preview registers its OAuth2Clients (modules/workloads auth = oidc); modules/dex's client_admission fences their ids. Empty grants nothing there."
  type        = string
  default     = ""
}

variable "name" {
  description = "Name of the ClusterRole, its binding, the dex Role and the admission policy; the namespace-admin ClusterRole is <name>-namespace-admin"
  type        = string
  default     = "preview-deployer"
}
