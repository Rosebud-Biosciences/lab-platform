# Plan-only assertions with a mocked AWS provider: namespace sanitisation and
# the optional read policy toggle.

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
  table_bucket_arn = "arn:aws:s3tables:us-west-2:123456789012:bucket/lakehouse"
  name_prefix      = "pr-123"
}

run "namespace_sanitised_no_read_policy" {
  command = plan

  assert {
    condition     = output.namespace == "pr_123"
    error_message = "dashes must be sanitised to underscores (S3 Tables namespaces allow only [a-z0-9_])"
  }
  assert {
    condition     = output.read_policy_arn == null
    error_message = "no read policy should be created when read_namespaces is empty"
  }
}

run "read_policy_created_when_namespaces_listed" {
  command = plan

  variables {
    read_namespaces = ["analytics", "raw"]
  }

  assert {
    condition     = length(aws_iam_policy.read) == 1
    error_message = "a read policy should be created when read_namespaces is non-empty"
  }
}

run "policies_live_under_the_preview_path" {
  command = plan

  assert {
    condition     = aws_iam_policy.readwrite.path == "/preview/"
    error_message = "the preview role may create policies under aws/bootstrap's preview path only"
  }
}

run "destroy_drops_the_namespace_tables" {
  command = plan

  assert {
    condition     = terraform_data.drop_tables[0].input.namespace == "pr_123" && terraform_data.drop_tables[0].input.region == "us-west-2"
    error_message = "the namespace's tables are dropped before it is deleted, in the bucket's region"
  }
}
