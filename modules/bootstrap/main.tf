# ------------------------------------------------------------------------------
# TOFU STATE BACKEND: S3 bucket + DynamoDB lock table
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
  tags   = var.tags

  # Plan-time layer of the same guard as the Deny policy below (dynamic
  # prevent_destroy; OpenTofu >= 1.12).
  lifecycle {
    prevent_destroy = var.state_bucket_prevent_destroy
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "state" {
  depends_on = [aws_s3_bucket_ownership_controls.state]
  bucket     = aws_s3_bucket.state.id
  acl        = "private"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (not a CMK): this bucket holds the state for every stack, including its
# own, so a key-policy mistake must not be able to lock you out of the run that
# would repair it, and a CMK would need kms grants on every principal that
# touches state (notably the preview role below).
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deletion guard: lifecycle.prevent_destroy only stops *tofu*, and only this
# configuration. A Deny bucket policy stops every principal (console, CLI,
# other stacks) from deleting the bucket that holds all state; removing the
# guard is a deliberate two-step (delete/edit the policy, then the bucket).
resource "aws_s3_bucket_policy" "prevent_destroy" {
  count = var.state_bucket_prevent_destroy ? 1 : 0

  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PreventStateBucketDeletion"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:DeleteBucket"
      Resource  = aws_s3_bucket.state.arn
    }]
  })
}

# State files are small and numerous; expire stale versions rather than tiering
# (Glacier's 90-day minimum + per-object overhead costs more here).
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.state_noncurrent_expiration_days
    }
  }
}

resource "aws_dynamodb_table" "locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  tags         = var.tags

  # Native deletion guard (unlike prevent_destroy it also blocks console/CLI).
  deletion_protection_enabled = var.lock_table_deletion_protection

  attribute {
    name = "LockID"
    type = "S"
  }
}
