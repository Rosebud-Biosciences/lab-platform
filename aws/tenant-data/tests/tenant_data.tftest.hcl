mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}
mock_provider "postgresql" {}
mock_provider "random" {}

variables {
  tenant            = "acme"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/ABC"
  oidc_issuer       = "https://oidc.eks.us-east-1.amazonaws.com/id/ABC"
  service_accounts  = ["t-acme-ray/ray-sa", "jupyterhub/jh-acme-research"]
  shared_bucket_arn = "arn:aws:s3:::lab-data"
}

run "shared_prefix" {
  command = plan

  assert {
    condition     = aws_iam_role.tenant.name == "tenant-acme" && output.storage_url == "s3://lab-data/tenants/acme/"
    error_message = "a role per tenant, a prefix of the shared bucket"
  }
  assert {
    condition     = tolist(local.assume_subjects) == tolist(["system:serviceaccount:t-acme-ray:ray-sa", "system:serviceaccount:jupyterhub:jh-acme-research"])
    error_message = "only the tenant's own ServiceAccounts may assume its role"
  }
  assert {
    condition     = tolist(local.object_arns) == tolist(["arn:aws:s3:::lab-data/tenants/acme/*"]) && local.list_prefixes == tolist(["tenants/acme/", "tenants/acme/*"])
    error_message = "objects and listing are confined to tenants/<tenant>/"
  }
  assert {
    condition     = length(module.bucket) == 0 && length(postgresql_database.tenant) == 0
    error_message = "no own bucket or database unless asked"
  }
}

run "own_bucket_and_database" {
  command = plan

  variables {
    bucket              = "own"
    database            = "own_database"
    database_connection = { host = "db.example.com" }
  }

  assert {
    condition     = length(module.bucket) == 1 && postgresql_database.tenant[0].name == "tenant_acme" && postgresql_role.owner[0].name == "tenant_acme"
    error_message = "a bucket of its own, and a database it owns"
  }
}

run "shared_prefix_needs_the_bucket" {
  command = plan

  variables {
    shared_bucket_arn = ""
    bucket            = "shared_prefix"
  }

  expect_failures = [aws_iam_role_policy.storage]
}
