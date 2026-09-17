# Plan-only assertions with a mocked AWS provider: prefix normalisation, the
# "grant something" guard, and the bucket_arn requirement.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock"
    }
  }
}

variables {
  name       = "pr123-data-access"
  bucket_arn = "arn:aws:s3:::prod-data"
}

run "prefixes_normalised_to_trailing_slash" {
  command = plan

  variables {
    prefixes = ["tether/greetings.icechunk", "tether/greetings.lance/"]
  }

  assert {
    condition     = output.prefixes == ["tether/greetings.icechunk/", "tether/greetings.lance/"]
    error_message = "every prefix must end with exactly one slash so the object ARN pattern stays inside the store"
  }
  assert {
    condition     = output.policy_name == "pr123-data-access"
    error_message = "the policy takes the caller's name"
  }
}

run "tables_only_needs_no_bucket" {
  command = plan

  variables {
    bucket_arn = ""
    table_arns = ["arn:aws:s3tables:us-west-2:123456789012:bucket/lakehouse/table/0000-1111"]
  }

  assert {
    condition     = length(output.prefixes) == 0
    error_message = "no S3 prefixes should be granted when none are listed"
  }
}

run "refuses_an_empty_grant" {
  command = plan

  variables {
    prefixes   = []
    table_arns = []
  }

  expect_failures = [aws_iam_policy.this]
}

run "prefixes_require_a_bucket" {
  command = plan

  variables {
    bucket_arn = ""
    prefixes   = ["tether/"]
  }

  expect_failures = [aws_iam_policy.this]
}
