# ------------------------------------------------------------------------------
# Hardened S3 bucket: private ACL, KMS encryption (own or shared key),
# versioning, lifecycle transitions, optional destroy-protection, and IAM
# get/put/putget policies that can be attached to callers.
#
# The AWS provider (including its region and default_tags) is configured by the
# caller and passed in -- this module never declares its own provider, so it can
# be used with count/for_each and published to the registry.
# ------------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  name = var.name
  tags = var.tags

  prevent_destroy = var.prevent_destroy
  force_destroy   = var.force_destroy
  versioning      = var.versioning

  account_root_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"

  aws_kms_key_arn = var.aws_kms_key_arn == "" ? aws_kms_key.this[0].arn : var.aws_kms_key_arn
  # Principal granted control over a *generated* key: caller override, else the
  # account root so IAM-policy-based access keeps working.
  deployment_user_arn = var.deployment_user_arn != "" ? var.deployment_user_arn : local.account_root_arn

  put_users    = var.put_users
  get_users    = var.get_users
  putget_users = var.putget_users
}

# ------------------------------------------------------------------------------
# Create bucket
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_18:access logging needs a destination bucket the consumer owns; opt in downstream
  #checkov:skip=CKV_AWS_21:versioning is var.versioning -- ephemeral preview buckets turn it off on purpose
  bucket        = local.name
  force_destroy = local.force_destroy
  tags          = local.tags

  # Plan-time guard (dynamic prevent_destroy; OpenTofu >= 1.12), layered with
  # the Deny bucket policy below, which also stops non-tofu principals
  # (console, CLI, other stacks).
  lifecycle {
    prevent_destroy = var.prevent_destroy
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "prevent_destroy" {
  count = local.prevent_destroy ? 1 : 0

  bucket = aws_s3_bucket.this.id
  policy = templatefile("${path.module}/policies/bucket_prevent_destroy.json", {
    bucket_arn = aws_s3_bucket.this.arn
  })
}

# ------------------------------------------------------------------------------
# Make private
# ------------------------------------------------------------------------------

# ACLs disabled outright (BucketOwnerEnforced): bucket policy and IAM are the
# only access control, and there is no aws_s3_bucket_acl to drift.
resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ------------------------------------------------------------------------------
# Encryption
# ------------------------------------------------------------------------------

resource "aws_kms_key" "this" {
  count = var.aws_kms_key_arn == "" ? 1 : 0

  description             = "Encrypts objects in the ${local.name} bucket"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.tags

  policy = templatefile("${path.module}/policies/key_default_policy.json", {
    user_arn        = local.deployment_user_arn
    prevent_destroy = local.prevent_destroy
  })

  # Plan-time guard (dynamic prevent_destroy; OpenTofu >= 1.12): follows
  # var.prevent_destroy, so ephemeral/preview buckets can still tear the key
  # down with `tofu destroy`. Layered with the "PreventKeyDeletion" Deny in
  # key_default_policy.json (same gate), which blocks
  # kms:ScheduleKeyDeletion for every principal.
  lifecycle {
    prevent_destroy = var.prevent_destroy
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.bucket

  rule {
    # Nothing here uses SSE-C (all access is SSE-KMS). Declaring the SSE-C block
    # explicitly matches AWS's anti-ransomware default and keeps plan/apply from
    # stripping it.
    blocked_encryption_types = ["SSE-C"]

    apply_server_side_encryption_by_default {
      kms_master_key_id = local.aws_kms_key_arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# ------------------------------------------------------------------------------
# Versioning
# ------------------------------------------------------------------------------

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = local.versioning ? "Enabled" : "Suspended"
  }
}

# ------------------------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  #checkov:skip=CKV_AWS_300:the abort-multipart rule below aborts incomplete uploads bucket-wide; checkov also wants it repeated in each other whole-bucket rule (the versioning one)
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "abort-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_upload_days
    }
  }

  dynamic "rule" {
    for_each = local.versioning ? [1] : []
    content {
      id     = "noncurrent"
      status = "Enabled"
      filter {}
      noncurrent_version_expiration {
        noncurrent_days = 90
      }
      dynamic "noncurrent_version_transition" {
        for_each = var.noncurrent_transition_days > 0 ? [1] : []
        content {
          noncurrent_days = var.noncurrent_transition_days
          storage_class   = var.noncurrent_transition_storage_class
        }
      }
    }
  }

  dynamic "rule" {
    for_each = var.transition_days > 0 ? [1] : []
    content {
      id     = "transition"
      status = "Enabled"
      filter {}
      transition {
        days          = var.transition_days
        storage_class = var.transition_storage_class
      }
    }
  }

  dynamic "rule" {
    for_each = var.deep_archive_transition_days > 0 ? [1] : []
    content {
      id     = "deep-archive-transition"
      status = "Enabled"
      filter {}
      transition {
        days          = var.deep_archive_transition_days
        storage_class = "DEEP_ARCHIVE"
      }
    }
  }

  # Explicit per-project archival: an archive runbook tags objects
  # archived=true and this rule moves them to DEEP_ARCHIVE on the next lifecycle
  # run (days = 0). S3 lifecycle skips objects smaller than 128 KB.
  dynamic "rule" {
    for_each = var.archive_tag_transition ? [1] : []
    content {
      id     = "tag-archive"
      status = "Enabled"
      filter {
        tag {
          key   = "archived"
          value = "true"
        }
      }
      transition {
        days          = 0
        storage_class = "DEEP_ARCHIVE"
      }
    }
  }
}

# ------------------------------------------------------------------------------
# Intelligent-Tiering
# ------------------------------------------------------------------------------

resource "aws_s3_bucket_intelligent_tiering_configuration" "this" {
  count  = var.intelligent_tiering_deep_archive_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.this.id
  name   = "deep-archive"

  dynamic "filter" {
    for_each = var.intelligent_tiering_prefix != "" ? [1] : []
    content {
      prefix = var.intelligent_tiering_prefix
    }
  }

  tiering {
    access_tier = "DEEP_ARCHIVE_ACCESS"
    days        = var.intelligent_tiering_deep_archive_days
  }
}

# ------------------------------------------------------------------------------
# Access policies
# ------------------------------------------------------------------------------

resource "aws_iam_policy" "put" {
  name        = "bucket-${local.name}-put"
  path        = "/"
  description = "Allow users to put objects in the ${local.name} bucket"

  policy = templatefile("${path.module}/policies/bucket_put.json", {
    bucket_arn  = aws_s3_bucket.this.arn
    kms_key_arn = local.aws_kms_key_arn
  })
}

resource "aws_iam_policy" "get" {
  name        = "bucket-${local.name}-get"
  path        = "/"
  description = "Allow users to get objects from the ${local.name} bucket"

  policy = templatefile("${path.module}/policies/bucket_get.json", {
    bucket_arn  = aws_s3_bucket.this.arn
    kms_key_arn = local.aws_kms_key_arn
  })
}

data "aws_iam_policy_document" "putget" {
  source_policy_documents = [
    for filename in ["bucket_put.json", "bucket_get.json"] :
    templatefile("${path.module}/policies/${filename}", {
      bucket_arn  = aws_s3_bucket.this.arn
      kms_key_arn = local.aws_kms_key_arn
    })
  ]
}

resource "aws_iam_policy" "putget" {
  name        = "bucket-${local.name}-putget"
  path        = "/"
  description = "Allow users to put and get objects in the ${local.name} bucket"

  policy = data.aws_iam_policy_document.putget.json
}

# ------------------------------------------------------------------------------
# Attach policies to existing IAM users (optional)
# ------------------------------------------------------------------------------

resource "aws_iam_user_policy_attachment" "put" {
  #checkov:skip=CKV_AWS_40:opt-in feature -- existing access-key users the consumer names in iam_users; roles are the default path
  for_each = toset(local.put_users)

  user       = each.value
  policy_arn = aws_iam_policy.put.arn
}

resource "aws_iam_user_policy_attachment" "get" {
  #checkov:skip=CKV_AWS_40:opt-in feature -- existing access-key users the consumer names in iam_users; roles are the default path
  for_each = toset(local.get_users)

  user       = each.value
  policy_arn = aws_iam_policy.get.arn
}

resource "aws_iam_user_policy_attachment" "putget" {
  #checkov:skip=CKV_AWS_40:opt-in feature -- existing access-key users the consumer names in iam_users; roles are the default path
  for_each = toset(local.putget_users)

  user       = each.value
  policy_arn = aws_iam_policy.putget.arn
}
