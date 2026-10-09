# ------------------------------------------------------------------------------
# WORKLOADS MODULE - JUPYTERHUB GROUP PROFILES (var.jupyterhub_group_profiles)
#
# One hub, per-group identities: a user is offered a server profile for each
# of their IdP groups that has one (and only those). A profile's server runs
# as the group's ServiceAccount (its cloud role, e.g. IRSA), with the group's
# Secret instead of the platform's identity Secret, the group's directory at
# ~/group, and -- when mount_shared is off -- without the hub-wide /home/shared.
# Group directories live on the HOME volume (groups/<tenant>/<group>), which
# users only ever see their own sub-path of; the shared volume is mounted
# whole for everyone, so it could not keep a group's files to the group.
# Requires JupyterHub on OIDC with groups (manage_groups, from the claim).
# ------------------------------------------------------------------------------

locals {
  jupyterhub_profiles = var.enable_jupyterhub ? {
    for path, p in var.jupyterhub_group_profiles : path => merge(p, {
      slug = replace(trimprefix(path, "/"), "/", "-")
    })
  } : {}

  jupyterhub_profiles_config = {
    for path, p in local.jupyterhub_profiles : path => {
      slug             = p.slug
      display_name     = coalesce(p.display_name, path)
      service_account  = kubernetes_service_account_v1.jupyterhub_profile[path].metadata[0].name
      secret           = kubernetes_secret_v1.jupyterhub_profile[path].metadata[0].name
      env              = p.env
      replace_identity = p.replace_identity
      mount_shared     = p.mount_shared
      group_directory  = p.group_directory
      subpath          = "groups${path}"
      # Stamps' NetworkPolicies admit a tenant's notebooks by these labels.
      labels = {
        "lab-platform.io/tenant" = split("/", trimprefix(path, "/"))[0]
        "lab-platform.io/group"  = p.slug
      }
    }
  }

  jupyterhub_profiles_values = length(local.jupyterhub_profiles) > 0 ? yamlencode({
    hub = {
      config = { GenericOAuthenticator = { manage_groups = true, claim_groups_key = var.auth.groups_claim } }
      extraConfig = {
        "10-group-profiles" = templatefile("${local.helm_defaults}/jupyterhub/group_profiles.py", {
          profiles_json = jsonencode(local.jupyterhub_profiles_config)
        })
      }
    }
  }) : ""
}

resource "kubernetes_service_account_v1" "jupyterhub_profile" {
  for_each = local.jupyterhub_profiles

  metadata {
    name        = "${local.prefix}jh-${each.value.slug}"
    namespace   = local.jupyterhub_namespace
    annotations = each.value.service_account_annotations
    labels      = { "lab-platform.io/group" = each.value.slug }
  }
}

resource "kubernetes_secret_v1" "jupyterhub_profile" {
  for_each = local.jupyterhub_profiles

  metadata {
    name      = "jh-${each.value.slug}-env"
    namespace = local.jupyterhub_namespace
  }

  data = each.value.secret_env
}
