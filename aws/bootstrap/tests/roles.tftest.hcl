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
