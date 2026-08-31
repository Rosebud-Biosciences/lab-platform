# The kubernetes / helm / kubectl providers, plus the aws.ecr_public_region
# alias, must be configured by the caller and passed in (see README for an
# example using the aws eks get-token exec plugin). This module declares the
# requirements but never configures a provider.
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 6.0"
      configuration_aliases = [aws.ecr_public_region]
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.12.1"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    helm = {
      source = "hashicorp/helm"
      # helm provider 3, required by eks-blueprints-addons >= 1.24. Fresh applies
      # are unaffected by the provider-2->3 state-migration bugs (those only bite
      # when adopting existing releases), so green-field consumers get helm 3
      # cleanly. Note the v3 syntax: the provider's kubernetes/exec are object
      # attributes (`=`), and helm_release set/set_sensitive are list attributes.
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.1.0"
    }
  }
}
