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
