# ------------------------------------------------------------------------------
# POSTGRES GROUP ROLES - one login role per data group
#
# nb_<tenant>__<group> connects from notebooks (a JupyterHub group profile's
# secret_env) and tenant compute. It owns nothing and can do only what
# member_of grants -- the app's app_notebook, whose row-level security policy
# reads the group back out of the name the role logged in with
# (session_user), so a role sees exactly its group's rows and cannot widen
# that with a session setting. The grant is a plain one (the provider cannot
# say WITH SET FALSE), so on PostgreSQL 16+ the role may SET ROLE
# app_notebook; that changes current_user, never session_user, and the
# template's migration 0004 is written for exactly that.
#
# Created by SQL through the postgresql provider, never Neon's role API: API-
# created Neon roles may SET ROLE neon_superuser, which bypasses row-level
# security.
# ------------------------------------------------------------------------------

locals {
  roles = {
    for g in var.groups : g => "nb_${replace(trimprefix(g, "/"), "/", "__")}"
  }
}

resource "random_password" "role" {
  for_each = local.roles

  length  = 40
  special = false
}

resource "postgresql_role" "group" {
  for_each = local.roles

  name             = each.value
  login            = true
  password         = random_password.role[each.key].result
  roles            = var.member_of
  connection_limit = var.connection_limit

  inherit                   = true
  create_database           = false
  create_role               = false
  superuser                 = false
  replication               = false
  bypass_row_level_security = false
}
