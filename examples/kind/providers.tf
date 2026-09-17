# All three providers read the kubeconfig kind wrote. Any other cluster works
# the same way: point kubeconfig_path / kube_context at it.
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  config_context   = var.kube_context
  load_config_file = true
}
