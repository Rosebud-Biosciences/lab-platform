# ------------------------------------------------------------------------------
# JUPYTERHUB EXAMPLE
#
# A multi-user JupyterHub lab with:
#   - per-user logins: each user sets their own password at first login
#     (firstuse auth) and only usernames on the allow list may claim an account;
#   - a per-user home directory (EFS sub-path per username) that survives
#     server restarts, PLUS a /home/shared directory every user can read/write;
#   - the marimo notebook extension available from the JupyterLab launcher.
#
# The user-data EFS filesystem is destroy-protected by default
# (jupyterhub_efs_prevent_destroy) — `tofu destroy` refuses until you disarm it.
# ------------------------------------------------------------------------------

module "network" {
  source = "../../modules/network"

  name        = "vpc-${var.environment}"
  environment = var.environment

  single_nat_gateway             = true
  enable_tailscale_subnet_router = false

  tags = var.tags
}

module "platform" {
  source = "../../modules/eks-platform"

  providers = {
    aws                   = aws
    aws.ecr_public_region = aws.ecr_public_region
    kubernetes            = kubernetes
    helm                  = helm
    kubectl               = kubectl
  }

  environment = var.environment
  region      = var.region

  vpc_id                      = module.network.vpc_id
  vpc_name                    = module.network.vpc_name
  private_subnets             = module.network.private_subnets
  private_subnets_cidr_blocks = module.network.private_subnets_cidr_blocks
  vpc_security_group_id       = module.network.default_security_group_id

  # Reachable from CI/laptops without a bastion/VPN for this demo.
  cluster_endpoint_public_access = true

  tags = var.tags
}

# marimo is installed at server start so the example works with any singleuser
# image. For production, bake `pip install marimo jupyter-marimo-proxy` into
# jupyterhub_singleuser_image instead: faster starts and no PyPI dependency at
# spawn time. jupyter-marimo-proxy adds a marimo tile to the JupyterLab
# launcher (via jupyter-server-proxy).
locals {
  marimo_values = yamlencode({
    singleuser = {
      lifecycleHooks = {
        postStart = {
          exec = {
            command = ["sh", "-c", "pip install --quiet marimo jupyter-marimo-proxy"]
          }
        }
      }
    }
  })
}

module "workloads" {
  source = "../../modules/workloads"

  providers = {
    aws        = aws
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  cluster_name                 = module.platform.cluster_name
  oidc_provider_arn            = module.platform.oidc_provider_arn
  region                       = var.region
  vpc_name                     = module.platform.vpc_name
  karpenter_node_iam_role_name = module.platform.karpenter_node_iam_role_name
  environment                  = var.environment

  # EFS placement for the user-data filesystem.
  vpc_id                      = module.network.vpc_id
  private_subnets             = module.network.private_subnets
  private_subnets_cidr_blocks = module.network.private_subnets_cidr_blocks
  vpc_secondary_cidr_blocks   = module.network.vpc_secondary_cidr_blocks

  enable_jupyterhub = true

  # Per-user logins without an IdP: first login sets the user's password.
  # Switch to "cognito" + extra values for real OIDC identity.
  jupyterhub_auth_mechanism = "firstuse"
  jupyterhub_admin_users    = var.jupyterhub_admin_users
  jupyterhub_allowed_users  = var.jupyterhub_allowed_users

  jupyterhub_singleuser_image = var.jupyterhub_singleuser_image

  # Keep the guard on: user home directories live on this filesystem.
  jupyterhub_efs_prevent_destroy = true

  jupyterhub_extra_values = [local.marimo_values]

  tags = var.tags
}
