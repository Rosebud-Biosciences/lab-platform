# ------------------------------------------------------------------------------
# TENANT DATA - one tenant's identity and slice of data
#
#   role       assumed (web identity) only by the tenant's own ServiceAccounts
#   storage    shared_prefix: read/write/delete under tenants/<tenant>/ of the
#              shared bucket, list only that prefix; own: a bucket and KMS key
#              of its own, nothing of anyone else's
#   database   own_database: a database whose owner role is the tenant's
# ------------------------------------------------------------------------------

locals {
  issuer_host = trimprefix(var.oidc_issuer, "https://")
  role_name   = "${var.name_prefix}tenant-${replace(var.tenant, "_", "-")}"

  own_bucket    = var.bucket == "own"
  prefix        = "tenants/${var.tenant}/"
  bucket_arn    = local.own_bucket ? module.bucket[0].aws_s3_bucket.arn : var.shared_bucket_arn
  bucket_name   = local.own_bucket ? module.bucket[0].aws_s3_bucket.bucket : try(regex("^arn:aws[a-z-]*:s3:::(.+)$", var.shared_bucket_arn)[0], "")
  kms_key_arn   = local.own_bucket ? module.bucket[0].aws_kms_key_arn : var.shared_bucket_kms_key_arn
  object_arns   = local.own_bucket ? ["${local.bucket_arn}/*"] : ["${local.bucket_arn}/${local.prefix}*"]
  storage_url   = local.own_bucket ? "s3://${local.bucket_name}/" : "s3://${local.bucket_name}/${local.prefix}"
  database_name = "tenant_${var.tenant}"

  assume_subjects = [for sa in var.service_accounts : "system:serviceaccount:${replace(sa, "/", ":")}"]
  list_prefixes   = local.own_bucket ? [] : [local.prefix, "${local.prefix}*"]
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:sub"
      values   = local.assume_subjects
    }
  }
}

resource "aws_iam_role" "tenant" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = merge(var.tags, { "lab-platform/tenant" = var.tenant })
}

module "bucket" {
  source = "../s3-bucket"
  count  = local.own_bucket ? 1 : 0

  name            = "${var.name_prefix}tenant-${replace(var.tenant, "_", "-")}"
  prevent_destroy = var.own_bucket_prevent_destroy
  tags            = merge(var.tags, { "lab-platform/tenant" = var.tenant })
}

data "aws_iam_policy_document" "storage" {
  statement {
    sid       = "ListOwnSlice"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]

    dynamic "condition" {
      for_each = length(local.list_prefixes) > 0 ? [1] : []
      content {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = local.list_prefixes
      }
    }
  }

  statement {
    sid       = "ReadWriteOwnSlice"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = local.object_arns
  }

  dynamic "statement" {
    for_each = local.kms_key_arn != "" && local.kms_key_arn != null ? [1] : []
    content {
      sid       = "UseBucketKey"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [local.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "storage" {
  name   = "storage"
  role   = aws_iam_role.tenant.id
  policy = data.aws_iam_policy_document.storage.json

  lifecycle {
    precondition {
      condition     = local.own_bucket || can(regex("^arn:aws[a-z-]*:s3:::.+$", var.shared_bucket_arn))
      error_message = "bucket = \"shared_prefix\" needs shared_bucket_arn."
    }
  }
}

# ------------------------------------------------------------------------------
# An own database (the caller's postgresql provider)
# ------------------------------------------------------------------------------

resource "random_password" "database" {
  count = var.database == "own_database" ? 1 : 0

  length  = 40
  special = false
}

resource "postgresql_role" "owner" {
  count = var.database == "own_database" ? 1 : 0

  name     = local.database_name
  login    = true
  password = random_password.database[0].result
}

resource "postgresql_database" "tenant" {
  count = var.database == "own_database" ? 1 : 0

  name  = local.database_name
  owner = postgresql_role.owner[0].name

  lifecycle {
    precondition {
      condition     = var.database_connection != null
      error_message = "database = \"own_database\" needs database_connection (for the URL the stamps receive)."
    }
  }
}
