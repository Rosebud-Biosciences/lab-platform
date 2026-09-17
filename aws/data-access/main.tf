# ------------------------------------------------------------------------------
# DATA ACCESS FOR DATASET BRANCHES (tether mode)
#
# When a dataset tool forks PRODUCTION stores per preview -- an Icechunk branch,
# a Lance branch, an Iceberg table branch -- the fork is a ref inside the same
# store, so the preview's pods need to write into prod's bucket and commit to
# prod's tables. This policy is the smallest grant that lets them:
#
#   - S3: get / put / list on the listed prefixes, never delete. Branch writes
#     only ever add objects (chunks, manifests, snapshots, ref files); deletion
#     belongs to garbage collection, which runs from an operator's credentials,
#     not a preview's. A preview with a bug can waste space, not lose data.
#   - S3 Tables: read and commit metadata on the listed tables. Iceberg branches
#     are refs in one metadata file, so there is nothing narrower to grant; a
#     preview that writes to `main` instead of its branch is a code bug the
#     dataset tool's log and `verify` catch, not one IAM prevents. Say so to
#     whoever adopts this mode.
#
# The tofu-mode counterparts (preview-storage, iceberg-branches) give a preview
# its own empty bucket and namespace instead, and need none of this.
# ------------------------------------------------------------------------------

locals {
  prefixes = [for p in var.prefixes : endswith(p, "/") ? p : "${p}/"]

  # <bucket-arn>/table/<id> -> <bucket-arn>: the discovery calls take the
  # table bucket, and the tables named may span several.
  table_bucket_arns = distinct([for a in var.table_arns : regex("^(.*)/table/[^/]+$", a)[0]])
}

data "aws_iam_policy_document" "this" {
  dynamic "statement" {
    for_each = length(local.prefixes) > 0 ? [1] : []
    content {
      sid       = "ListPrefixes"
      actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
      resources = [var.bucket_arn]

      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = concat(local.prefixes, [for p in local.prefixes : "${p}*"])
      }
    }
  }

  dynamic "statement" {
    for_each = length(local.prefixes) > 0 ? [1] : []
    content {
      sid = "ReadWritePrefixesNoDelete"
      actions = [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
      ]
      resources = [for p in local.prefixes : "${var.bucket_arn}/${p}*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.table_arns) > 0 ? [1] : []
    content {
      sid = "TableBucketDiscovery"
      actions = [
        "s3tables:GetTableBucket",
        "s3tables:GetNamespace",
        "s3tables:ListNamespaces",
        "s3tables:ListTables",
      ]
      resources = local.table_bucket_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.table_arns) > 0 ? [1] : []
    content {
      sid = "ReadCommitTables"
      actions = [
        "s3tables:GetTable",
        "s3tables:GetTableData",
        "s3tables:PutTableData",
        "s3tables:GetTableMetadataLocation",
        "s3tables:UpdateTableMetadataLocation",
      ]
      resources = var.table_arns
    }
  }
}

resource "aws_iam_policy" "this" {
  name        = var.name
  description = "Read/write (no delete) on production data-store prefixes and read/commit on listed Iceberg tables, for pods working on dataset branches"
  policy      = data.aws_iam_policy_document.this.json
  tags        = var.tags

  lifecycle {
    precondition {
      condition     = length(var.prefixes) + length(var.table_arns) > 0
      error_message = "data-access: give it something to grant -- at least one of prefixes or table_arns."
    }
    precondition {
      condition     = length(var.prefixes) == 0 || var.bucket_arn != ""
      error_message = "data-access: bucket_arn is required when prefixes is non-empty."
    }
  }
}
