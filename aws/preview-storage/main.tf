# ------------------------------------------------------------------------------
# EPHEMERAL PROCESSED-DATA BUCKET
#
# A disposable processed-data bucket for a single preview. force_destroy = true
# so `tofu destroy` removes it even when the preview run wrote objects; no
# versioning (nothing here is worth keeping). Its own KMS key (scheduled for
# deletion on destroy since prevent_destroy = false).
# ------------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  prefix           = var.name_prefix
  bucket_name      = "${var.bucket_base_name}-${local.prefix}"
  account_root_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
}

module "processeddata" {
  source = "../s3-bucket"

  name     = local.bucket_name
  iam_path = var.iam_path
  tags     = var.tags

  # Ephemeral: never protect, always allow a non-empty destroy.
  prevent_destroy = false
  force_destroy   = true
  versioning      = false

  # Own KMS key (root principal so IAM-based access keeps working).
  deployment_user_arn = local.account_root_arn

  put_users    = []
  get_users    = []
  putget_users = []
}
