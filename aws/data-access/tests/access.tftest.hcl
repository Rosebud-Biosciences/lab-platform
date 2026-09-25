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

run "an_sse_kms_bucket_grants_its_key" {
  command = plan

  variables {
    prefixes    = ["tether/"]
    kms_key_arn = "arn:aws:kms:us-west-2:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
  }

  assert {
    condition     = local.kms_grant
    error_message = "objects in an SSE-KMS bucket need Decrypt / GenerateDataKey on its key"
  }
}

run "no_key_grant_without_a_key_or_prefixes" {
  command = plan

  variables {
    bucket_arn  = ""
    table_arns  = ["arn:aws:s3tables:us-west-2:123456789012:bucket/lakehouse/table/0000-1111"]
    kms_key_arn = "arn:aws:kms:us-west-2:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
  }

  assert {
    condition     = !local.kms_grant
    error_message = "the bucket key is granted only alongside object access"
  }
}

run "kms_key_arn_must_be_a_key_arn" {
  command = plan

  variables {
    prefixes    = ["tether/"]
    kms_key_arn = "alias/prod-data"
  }

  expect_failures = [var.kms_key_arn]
}

run "no_delete_by_default" {
  command = plan

  variables {
    prefixes = ["tether/"]
  }

  assert {
    condition     = length([for s in data.aws_iam_policy_document.this.statement : s if contains(s.actions, "s3:DeleteObject")]) == 0
    error_message = "the policy pods hold must never delete"
  }
}

run "working_branch_deletes_reach_only_branch_keys" {
  command = plan

  variables {
    prefixes              = ["tether/"]
    working_branch_prefix = "tether.ws."
  }

  assert {
    condition = toset(flatten([
      for s in data.aws_iam_policy_document.this.statement : s.resources if contains(s.actions, "s3:DeleteObject")
      ])) == toset([
      "arn:aws:s3:::prod-data/tether/*/_refs/branches/tether.ws.*",
      "arn:aws:s3:::prod-data/tether/*/tree/tether.ws.*",
    ])
    error_message = "the working-branch grant deletes a Lance branch's ref and tree, never a store's own keys"
  }
}

run "working_branch_prefix_cannot_widen" {
  command = plan

  variables {
    prefixes              = ["tether/"]
    working_branch_prefix = "*"
  }

  expect_failures = [var.working_branch_prefix]
}

run "allow_delete_covers_the_prefixes" {
  command = plan

  variables {
    prefixes     = ["tether/"]
    allow_delete = true
  }

  assert {
    condition = toset(flatten([
      for s in data.aws_iam_policy_document.this.statement : s.resources if contains(s.actions, "s3:DeleteObject")
    ])) == toset(["arn:aws:s3:::prod-data/tether/*"])
    error_message = "the teardown grant deletes anything under the prefixes"
  }
}
