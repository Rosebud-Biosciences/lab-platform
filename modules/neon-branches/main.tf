# ------------------------------------------------------------------------------
# EPHEMERAL NEON BRANCHES (copy-on-write clones of the parent branches)
#
# A Neon branch is a snapshot of a whole project -- every database on the
# parent, at one instant -- and a compute (endpoint) belongs to the branch. So
# the unit of branching is the (project, parent branch) pair, not the
# database: sources that share a parent are served by ONE branch and ONE
# endpoint, with a connection string per database. This is what makes a
# single-project layout (app + dagster + mlflow in one project) cost one
# compute per preview instead of three, and gives every database of a preview
# the same snapshot. Sources in different projects still get their own branch,
# exactly as before, and a group of one keeps the branch name <prefix><source>.
#
# The derived connection strings are exported per source for the workloads
# module to consume. Everything here is deleted on `tofu destroy`, so no
# preview writes persist.
# ------------------------------------------------------------------------------

locals {
  prefix  = var.name_prefix
  sources = var.branch_sources

  # Group sources by parent. The group key is the sorted source names joined
  # with "-" (a single source keeps its own name), so state addresses stay
  # readable and a lone source's branch keeps the pre-grouping name.
  parent_of = { for k, v in local.sources : k => "${v.project_id}/${v.parent_branch_id}" }
  groups = {
    for parent in distinct(values(local.parent_of)) :
    join("-", sort([for k, p in local.parent_of : k if p == parent])) => {
      project_id       = split("/", parent)[0]
      parent_branch_id = split("/", parent)[1]
      sources          = sort([for k, p in local.parent_of : k if p == parent])
    }
  }
  group_of = { for g, spec in local.groups : g => spec.sources }
  source_group = {
    for k in keys(local.sources) :
    k => one([for g, members in local.group_of : g if contains(members, k)])
  }
}

resource "neon_branch" "this" {
  for_each = local.groups

  project_id = each.value.project_id
  parent_id  = each.value.parent_branch_id
  name       = "${local.prefix}${each.key}"
  protected  = "no"
}

resource "neon_endpoint" "this" {
  for_each = local.groups

  project_id = each.value.project_id
  branch_id  = neon_branch.this[each.key].id

  autoscaling_limit_min_cu = var.autoscaling_min_cu
  autoscaling_limit_max_cu = var.autoscaling_max_cu
  suspend_timeout_seconds  = var.suspend_timeout_seconds
}

# One password lookup per source: roles differ per database even on a shared
# branch.
data "neon_branch_role_password" "this" {
  for_each = local.sources

  project_id = each.value.project_id
  branch_id  = neon_branch.this[local.source_group[each.key]].id
  role_name  = each.value.role_name
}

locals {
  # Connection details per branched DB, keyed by the logical source name.
  connections = {
    for k, v in local.sources : k => {
      host     = neon_endpoint.this[local.source_group[k]].host
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
