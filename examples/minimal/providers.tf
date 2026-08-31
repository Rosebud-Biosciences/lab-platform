provider "aws" {
  region = var.region
}

# eks-blueprints-addons pulls a handful of controller images from the public
# ECR registry, which only lives in us-east-1.
provider "aws" {
  alias  = "ecr_public_region"
  region = "us-east-1"
}

# The kubernetes/helm/kubectl providers point at the cluster the platform module
# creates. Because provider config is read during plan, the very first apply
# must create the cluster before the workloads that use these providers -- see
# the README for the two-step (-target) apply order.
provider "kubernetes" {
  host                   = module.platform.cluster_endpoint
  cluster_ca_certificate = base64decode(module.platform.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.platform.cluster_name, "--region", var.region]
  }
}

# helm provider 3: kubernetes/exec are object attributes (`=`), unlike the
# kubernetes and kubectl providers above, which keep block syntax.
provider "helm" {
  kubernetes = {
    host                   = module.platform.cluster_endpoint
    cluster_ca_certificate = base64decode(module.platform.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.platform.cluster_name, "--region", var.region]
    }
  }
}

provider "kubectl" {
  host                   = module.platform.cluster_endpoint
  cluster_ca_certificate = base64decode(module.platform.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.platform.cluster_name, "--region", var.region]
  }
}
