mock_provider "postgresql" {}
mock_provider "random" {}

variables {
  groups     = ["/lab/authors", "/acme/research"]
  connection = { host = "db.example.com", database = "app" }
}

run "one_login_role_per_group" {
  command = plan

  assert {
    condition     = output.roles == { "/lab/authors" = "nb_lab__authors", "/acme/research" = "nb_acme__research" }
    error_message = "nb_<tenant>__<group>, which the app's RLS maps back to the path"
  }
  assert {
    condition     = postgresql_role.group["/lab/authors"].login && postgresql_role.group["/lab/authors"].roles == toset(["app_notebook"]) && !postgresql_role.group["/lab/authors"].bypass_row_level_security && !postgresql_role.group["/lab/authors"].create_role
    error_message = "a plain login role, member of app_notebook only, never above row-level security"
  }
}

run "paths_must_be_tenant_and_group" {
  command = plan

  variables {
    groups = ["/lab", "/lab/a__b"]
  }

  expect_failures = [var.groups]
}

run "trailing_underscore_is_refused" {
  command = plan

  variables {
    groups = ["/lab_/authors"]
  }

  expect_failures = [var.groups]
}
