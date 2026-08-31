# ------------------------------------------------------------------------------
# EPHEMERAL NEON BRANCHES (copy-on-write clones of the parent branches)
#
# One branch + endpoint per source project. The derived connection strings are
# exported for the workloads module to consume. Everything here is deleted on
# `tofu destroy`, so no preview writes persist.
# ------------------------------------------------------------------------------

locals {
  prefix  = var.name_prefix
  sources = var.branch_sources
}

resource "neon_branch" "this" {
  for_each = local.sources

  project_id = each.value.project_id
  parent_id  = each.value.parent_branch_id
  name       = "${local.prefix}${each.key}"
  protected  = "no"
}

resource "neon_endpoint" "this" {
  for_each = local.sources

  project_id = each.value.project_id
  branch_id  = neon_branch.this[each.key].id

  autoscaling_limit_min_cu = var.autoscaling_min_cu
  autoscaling_limit_max_cu = var.autoscaling_max_cu
  suspend_timeout_seconds  = var.suspend_timeout_seconds
}

data "neon_branch_role_password" "this" {
  for_each = local.sources

  project_id = each.value.project_id
  branch_id  = neon_branch.this[each.key].id
  role_name  = each.value.role_name
}

locals {
  # Connection details per branched DB, keyed by the logical source name.
  connections = {
    for k, v in local.sources : k => {
      host     = neon_endpoint.this[k].host
      user     = v.role_name
      password = data.neon_branch_role_password.this[k].password
      dbname   = v.db_name
    }
  }

  # Ready-to-use SQLAlchemy-style URLs per source (sslmode=require).
  postgres_urls = {
    for k, c in local.connections :
    k => "postgresql+psycopg://${c.user}:${urlencode(c.password)}@${c.host}/${c.dbname}?sslmode=require"
  }
}
