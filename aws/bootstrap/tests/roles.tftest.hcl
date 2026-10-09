# The CI and preview deployer roles are independently toggleable; disabling one
# yields a null role ARN and creates no IAM role of that family. Plan-only,
# mocked providers.

mock_provider "aws" {
  # The real aws_iam_policy_document data source renders JSON; the mock returns a
  # random string by default, which fails the provider's JSON validation once
  # fed into an IAM role/policy. Pin it to a valid (empty) policy document.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # Same problem one step on: the mock's random `arn` fails ARN validation when
  # a role_policy_attachment consumes it.
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock"
    }
  }
}

variables {
  state_bucket_name = "my-org-terraform-state-test"
}

run "roles_enabled_by_default" {
  command = plan

  assert {
    condition     = output.ci_deployer_role_arn != null
    error_message = "the CI deployer role should be created by default"
  }
  assert {
    condition     = output.preview_deployer_role_arn != null
    error_message = "the preview deployer role should be created by default"
  }
}

# A repository created (or renamed, or transferred) since 2026-07-15 gets
# Actions tokens whose subject carries its owner's and its own numeric ID; the
# name-only pattern matches none of them.
run "immutable_subjects_for_listed_repositories" {
  command = plan

  variables {
    github_owner          = "my-org"
    github_owner_id       = "123"
    github_repository_ids = { app = "456" }
    ci_repos              = ["app"]
    preview_repos         = ["app", "legacy"]
  }

  assert {
    condition = toset(flatten([
      for c in data.aws_iam_policy_document.ci_assume[0].statement[0].condition : c.values
      if c.variable == "token.actions.githubusercontent.com:sub"
    ])) == toset(["repo:my-org@123/app@456:*"])
    error_message = "a repository with a known ID is trusted under its immutable subject only"
  }
  assert {
    condition = toset(flatten([
      for c in data.aws_iam_policy_document.preview_assume[0].statement[0].condition : c.values
      if c.variable == "token.actions.githubusercontent.com:sub"
    ])) == toset(["repo:my-org@123/app@456:*", "repo:my-org/legacy:*"])
    error_message = "an unlisted repository keeps the name-only subject"
  }
}

run "teardown_role_off_by_default" {
  command = plan

  assert {
    condition     = output.teardown_role_arn == null
    error_message = "the teardown role is opt-in"
  }
}

run "teardown_role_trusts_one_ref_only" {
  command = plan

  variables {
    github_owner          = "my-org"
    github_owner_id       = "123"
    github_repository_ids = { app = "456" }
    enable_teardown_role  = true
    teardown_repos        = ["app"]
  }

  assert {
    condition = [
      for c in data.aws_iam_policy_document.teardown_assume[0].statement[0].condition : c
      if c.variable == "token.actions.githubusercontent.com:sub"
    ][0].test == "StringEquals"
    error_message = "the subject must match exactly: a pattern could admit pull_request runs"
  }
  assert {
    condition = toset(flatten([
      for c in data.aws_iam_policy_document.teardown_assume[0].statement[0].condition : c.values
      if c.variable == "token.actions.githubusercontent.com:sub"
    ])) == toset(["repo:my-org@123/app@456:ref:refs/heads/main"])
    error_message = "only the default branch's runs, under the immutable subject, may assume the teardown role"
  }
  assert {
    condition     = output.teardown_role_arn != null
    error_message = "enabling the teardown role creates it"
  }
}

run "teardown_role_needs_repositories" {
  command = plan

  variables {
    enable_teardown_role = true
  }

  expect_failures = [aws_iam_role.teardown]
}

run "repository_ids_need_the_owner_id" {
  command = plan

  variables {
    github_owner          = "my-org"
    github_repository_ids = { app = "456" }
  }

  expect_failures = [var.github_repository_ids]
}

run "roles_disabled" {
  command = plan

  variables {
    enable_ci_deployer_role      = false
    enable_preview_deployer_role = false
  }

  assert {
    condition     = output.ci_deployer_role_arn == null
    error_message = "no CI deployer role should exist when enable_ci_deployer_role = false"
  }
  assert {
    condition     = output.preview_deployer_role_arn == null
    error_message = "no preview deployer role should exist when enable_preview_deployer_role = false"
  }
}

# The operator role is opt-in (it needs principal ARNs the module cannot guess),
# and enabling it brings the guardrail policy with it.

run "operator_role_off_by_default" {
  command = plan

  assert {
    condition     = output.operator_admin_role_arn == null
    error_message = "the operator role should not be created unless enable_operator_admin_role = true"
  }
  assert {
    condition     = output.operator_guardrails_policy_arn == null
    error_message = "no guardrail policy should exist without the operator role"
  }
}

run "operator_role_enabled" {
  command = plan

  variables {
    enable_operator_admin_role = true
    operator_principal_arns    = ["arn:aws:iam::123456789012:user/alice"]
  }

  assert {
    condition     = output.operator_admin_role_arn != null
    error_message = "the operator role should be created when enabled"
  }
  assert {
    condition     = output.operator_guardrails_policy_arn != null
    error_message = "the guardrail policy should be created alongside the operator role"
  }
  assert {
    condition     = aws_iam_role.operator_admin[0].max_session_duration == 14400
    error_message = "the default session bound should be four hours"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.operator_admin) == 1
    error_message = "the default permission set is a single managed policy (AdministratorAccess)"
  }
}

run "operator_role_requires_principals" {
  command = plan

  variables {
    enable_operator_admin_role = true
    operator_principal_arns    = []
  }

  expect_failures = [aws_iam_role.operator_admin[0]]
}

# The preview role runs whatever a PR's workflow says: it manages only roles
# and policies under preview_iam_path, and only roles capped by the boundary.
run "preview_iam_is_confined_and_bounded" {
  command = plan

  assert {
    condition     = endswith(local.preview_managed_role_arns[0], ":role/preview/*") && endswith(local.preview_managed_policy_arns[0], ":policy/preview/*")
    error_message = "preview IAM is confined to the /preview/ path, never a name pattern prod roles can match"
  }
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.preview_deployer[0].statement : anytrue([for c in s.condition : c.variable == "iam:PermissionsBoundary"])
      if length(setintersection(toset(s.actions), toset(["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:PutRolePermissionsBoundary"]))) > 0
    ])
    error_message = "creating a role, or giving one permissions, requires the preview boundary on it"
  }
  assert {
    condition = length([
      for s in data.aws_iam_policy_document.preview_deployer[0].statement : s.sid
      if length(setintersection(toset(s.actions), toset(["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:PutRolePermissionsBoundary"]))) > 0
    ]) == 2
    error_message = "exactly the two boundary-conditioned statements grant role creation and permissions"
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.preview_deployer[0].statement :
      contains(s.actions, "iam:AttachRolePolicy") && anytrue([for c in s.condition : c.variable == "iam:PolicyARN" && alltrue([for v in c.values : endswith(v, ":policy/preview/*")])])
    ])
    error_message = "only the preview stack's own policies may be attached"
  }
  assert {
    condition = !anytrue(flatten([
      for s in data.aws_iam_policy_document.preview_boundary[0].statement : [for a in s.actions : can(regex("^(iam|sts):", a))] if s.effect == "Allow"
    ])) && output.preview_iam_path == "/preview/"
    error_message = "the boundary grants no IAM or STS"
  }
}

# A PR writes its preview roles' policies; the boundary is what caps them. By
# default it reaches only what a preview owns, and S3 -- whose ARNs name no
# account -- only in this one.
run "preview_boundary_reaches_only_what_a_preview_owns" {
  command = plan

  assert {
    condition = [
      for s in data.aws_iam_policy_document.preview_boundary[0].statement : s.sid
      if s.effect == "Allow" && contains(s.resources, "*")
    ] == ["EcrAuth"]
    error_message = "only ecr:GetAuthorizationToken, which has no resource, may name every resource"
  }
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.preview_boundary[0].statement :
      anytrue([for c in s.condition : c.variable == "aws:ResourceAccount" && toset(c.values) == toset([data.aws_caller_identity.current.account_id])])
      if anytrue([for a in s.actions : startswith(a, "s3:")]) && s.effect == "Allow"
    ])
    error_message = "every S3 grant is pinned to this account"
  }
  assert {
    condition = toset([for s in data.aws_iam_policy_document.preview_boundary[0].statement : s.resources if s.sid == "S3Delete"
    ][0]) == toset(["arn:aws:s3:::preview-processeddata-*/*"])
    error_message = "by default a preview deletes only in its own ephemeral bucket"
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.preview_boundary[0].statement :
      s.sid == "PreviewKeys" && anytrue([for c in s.condition : c.variable == "aws:ResourceTag/Environment" && toset(c.values) == toset(["preview"])])
    ])
    error_message = "a preview uses only keys tagged as a preview's"
  }
  assert {
    condition     = !anytrue([for s in data.aws_iam_policy_document.preview_boundary[0].statement : s.sid == "OnlyThroughTheClusterIssuers"])
    error_message = "the federated-provider check is opt-in"
  }
}

# tether mode's prod stores, as aws/data-access grants them: readable,
# writable under the data prefixes, deletable only as Lance working branches.
run "preview_boundary_access_lists_land_where_they_belong" {
  command = plan

  variables {
    preview_table_bucket_arns = ["arn:aws:s3tables:us-west-2:123456789012:bucket/lake"]
    preview_boundary_access = {
      read  = ["arn:aws:s3:::data"]
      write = ["arn:aws:s3:::data/tether/*", "arn:aws:s3tables:us-west-2:123456789012:bucket/lake/table/t1"]
      delete = [
        "arn:aws:s3:::data/tether/*/_refs/branches/tether.ws.*",
        "arn:aws:s3:::data/tether/*/tree/tether.ws.*",
      ]
      kms_key_arns = ["arn:aws:kms:us-west-2:123456789012:key/data"]
    }
    preview_boundary_federated_providers = ["arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/*"]
  }

  assert {
    condition = toset([
      for s in data.aws_iam_policy_document.preview_boundary[0].statement : s.resources if s.sid == "S3Read"
      ][0]) == toset([
      "arn:aws:s3:::preview-processeddata-*", "arn:aws:s3:::preview-processeddata-*/*", "arn:aws:s3:::data",
      "arn:aws:s3:::data/tether/*", "arn:aws:s3:::data/tether/*/_refs/branches/tether.ws.*", "arn:aws:s3:::data/tether/*/tree/tether.ws.*",
    ])
    error_message = "reads reach the ephemeral bucket and every listed store"
  }
  assert {
    condition = toset([for s in data.aws_iam_policy_document.preview_boundary[0].statement : s.resources if s.sid == "S3Write"
    ][0]) == toset(["arn:aws:s3:::preview-processeddata-*/*", "arn:aws:s3:::data/tether/*"])
    error_message = "writes reach the ephemeral bucket and the write list only"
  }
  assert {
    condition = toset([for s in data.aws_iam_policy_document.preview_boundary[0].statement : s.resources if s.sid == "S3Delete"
      ][0]) == toset([
      "arn:aws:s3:::preview-processeddata-*/*",
      "arn:aws:s3:::data/tether/*/_refs/branches/tether.ws.*",
      "arn:aws:s3:::data/tether/*/tree/tether.ws.*",
    ])
    error_message = "a preview deletes its own bucket's objects and the listed working branches, never the data prefixes"
  }
  assert {
    condition = toset([for s in data.aws_iam_policy_document.preview_boundary[0].statement : s.resources if s.sid == "TablesWrite"
    ][0]) == toset(["arn:aws:s3tables:us-west-2:123456789012:bucket/lake/table/t1"])
    error_message = "a preview commits only to the listed prod tables outside its own namespaces"
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.preview_boundary[0].statement :
      s.sid == "TablesInPreviewNamespaces" && anytrue([for c in s.condition : c.variable == "s3tables:namespace" && toset(c.values) == toset(["pr*"])])
    ])
    error_message = "table creation and drops stay in the preview namespaces"
  }
  assert {
    condition = toset([for s in data.aws_iam_policy_document.preview_boundary[0].statement : s.resources if s.sid == "DataKeys"
    ][0]) == toset(["arn:aws:kms:us-west-2:123456789012:key/data"])
    error_message = "the listed store keys are usable"
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.preview_boundary[0].statement :
      s.sid == "OnlyThroughTheClusterIssuers" && s.effect == "Deny" && anytrue([for c in s.condition : c.test == "StringNotLike" && c.variable == "aws:FederatedProvider"])
    ])
    error_message = "with providers listed, any other session is denied"
  }
}

run "preview_iam_path_is_not_the_root" {
  command = plan

  variables {
    preview_iam_path = "/"
  }

  expect_failures = [var.preview_iam_path]
}

run "preview_boundary_refuses_iam_actions" {
  command = plan

  variables {
    preview_boundary_extra_actions = ["iam:PassRole"]
  }

  expect_failures = [var.preview_boundary_extra_actions]
}

# The state bucket also holds prod's state, and state holds secrets: the
# preview role reads its own workspaces (and the one default-workspace object
# it is given), and no preview role can be granted the bucket at all.
run "preview_reads_only_its_own_state" {
  command = plan

  variables {
    preview_state_read_keys = ["template-app/terraform.tfstate"]
  }

  assert {
    condition = [
      for s in data.aws_iam_policy_document.preview_deployer[0].statement : toset(s.resources) if s.sid == "TfStateRead"
    ][0] == toset(["${aws_s3_bucket.state.arn}/preview/*", "${aws_s3_bucket.state.arn}/template-app/terraform.tfstate"])
    error_message = "state reads are the preview prefix plus the named keys, never the whole bucket"
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.preview_boundary[0].statement :
      s.effect == "Deny" && contains(s.resources, "${aws_s3_bucket.state.arn}/*") && contains(s.resources, aws_s3_bucket.state.arn)
    ])
    error_message = "the boundary denies every preview role the state bucket"
  }
}
