# AWS compute-axis adapter for modules/workloads: everything bound to an EKS
# cluster and its VPC rather than to the data -- the EFS volume behind
# JupyterHub homes, the ALB/ACM/WAF edge for public Ingresses, and the
# Karpenter NodePools pods are placed on. Emits workloads' scheduling,
# jupyterhub_shared_storage and public-ingress contract inputs.
# Providers (aws, helm) are inherited from the caller; helm points at the EKS
# cluster for the NodePool releases.
terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}
