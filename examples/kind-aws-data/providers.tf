provider "aws" {
  region = var.region
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = "kind-${var.cluster_name}"
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = "kind-${var.cluster_name}"
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  config_context   = "kind-${var.cluster_name}"
  load_config_file = true
}
