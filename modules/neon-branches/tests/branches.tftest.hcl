# Branching happens per (project, parent branch), not per database: sources
# that share a parent share one branch and one endpoint; sources in different
# projects each get their own, named as before. Plan-only against a mocked
# provider.

mock_provider "neon" {
  mock_resource "neon_branch" {
    defaults = { id = "br-mock" }
  }
  mock_resource "neon_endpoint" {
    defaults = { host = "ep-mock.neon.tech" }
  }
  mock_data "neon_branch_role_password" {
    defaults = { password = "pw" }
  }
}

# One project, three databases (the sandbox layout): one branch, one compute.
run "shared_parent_means_one_branch" {
  command = plan

  variables {
    name_prefix = "pr7-"
    branch_sources = {
      app     = { project_id = "proj-a", parent_branch_id = "br-main", role_name = "app", db_name = "app" }
      dagster = { project_id = "proj-a", parent_branch_id = "br-main", role_name = "dagster", db_name = "dagster" }
      argo    = { project_id = "proj-a", parent_branch_id = "br-main", role_name = "argo", db_name = "argo" }
    }
  }

  assert {
    condition     = length(neon_branch.this) == 1 && length(neon_endpoint.this) == 1
    error_message = "three databases on one parent must yield exactly one branch and one endpoint"
  }
  assert {
    condition     = neon_branch.this["app-argo-dagster"].name == "pr7-app-argo-dagster"
    error_message = "the shared branch is named after the prefix and its sorted sources"
  }
  assert {
    condition     = length(data.neon_branch_role_password.this) == 3
    error_message = "each database still gets its own role password"
  }
  assert {
    condition     = output.branch_names.app == output.branch_names.dagster && output.branch_names.dagster == output.branch_names.argo
    error_message = "every source reports the same branch"
  }
  assert {
    condition     = toset(output.branches["app-argo-dagster"].sources) == toset(["app", "dagster", "argo"])
    error_message = "the branches output lists which sources a branch serves"
  }
}

# Three projects (the per-service layout): three branches named as before the
# grouping existed.
run "distinct_parents_keep_one_branch_each" {
  command = plan

  variables {
    name_prefix = "pr7-"
    branch_sources = {
      app     = { project_id = "proj-app", parent_branch_id = "br-1", role_name = "app", db_name = "app" }
      dagster = { project_id = "proj-dagster", parent_branch_id = "br-2", role_name = "dagster", db_name = "dagster" }
      mlflow  = { project_id = "proj-mlflow", parent_branch_id = "br-3", role_name = "mlflow", db_name = "mlflow" }
    }
  }

  assert {
    condition     = length(neon_branch.this) == 3
    error_message = "one branch per project"
  }
  assert {
    condition     = neon_branch.this["app"].name == "pr7-app" && neon_branch.this["dagster"].name == "pr7-dagster" && neon_branch.this["mlflow"].name == "pr7-mlflow"
    error_message = "a group of one keeps the <prefix><source> branch name"
  }
  assert {
    condition     = output.branch_names.mlflow == "pr7-mlflow"
    error_message = "branch_names stays keyed by source"
  }
}

# Mixed: two projects, one of them holding two databases.
run "mixed_layout" {
  command = plan

  variables {
    name_prefix = "pr7-"
    branch_sources = {
      app     = { project_id = "proj-data", parent_branch_id = "br-1", role_name = "app", db_name = "app" }
      mlflow  = { project_id = "proj-data", parent_branch_id = "br-1", role_name = "mlflow", db_name = "mlflow" }
      dagster = { project_id = "proj-orch", parent_branch_id = "br-2", role_name = "dagster", db_name = "dagster" }
    }
  }

  assert {
    condition     = length(neon_branch.this) == 2 && contains(keys(neon_branch.this), "app-mlflow") && contains(keys(neon_branch.this), "dagster")
    error_message = "two parents, two branches: one shared by app+mlflow, one for dagster"
  }
  assert {
    condition     = neon_branch.this["app-mlflow"].project_id == "proj-data" && neon_branch.this["dagster"].project_id == "proj-orch"
    error_message = "each branch is cut in its sources' project"
  }
}

run "no_sources_creates_nothing" {
  command = plan

  variables {
    name_prefix    = "pr7-"
    branch_sources = {}
  }

  assert {
    condition     = length(neon_branch.this) == 0 && length(output.branches) == 0
    error_message = "an empty source map is a no-op"
  }
}
