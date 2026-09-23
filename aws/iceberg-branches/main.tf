# ------------------------------------------------------------------------------
# EPHEMERAL ICEBERG NAMESPACE (per preview)
#
# The Iceberg analogue of the Neon copy-on-write branch: each preview gets its
# own namespace in the SHARED S3 Tables table bucket, plus IAM policies that
# scope the preview's pods to (a) read/write tables only inside that namespace
# and (b) optionally read the listed prod namespaces. Nothing a preview writes
# can land in a prod table, and `destroy` removes the namespace with the rest
# of the stamp.
#
# Two isolation levels, only the first of which is Terraform's job:
#   1. Namespace-per-preview (this module): a clean, disposable schema-space;
#      the app's migrations create the tables it needs.
#   2. Table-level Iceberg branch refs (copy-on-write reads of PROD data):
#      branch refs are catalog data-plane operations, created by an engine, not
#      by IaC -- see the README for the pyiceberg one-liner CI can run.
# ------------------------------------------------------------------------------

locals {
  # S3 Tables namespaces only allow [a-z0-9_], e.g. "pr-123" -> "pr_123".
  namespace = replace(lower(var.name_prefix), "/[^a-z0-9_]/", "_")

  # Tables live at <bucket_arn>/table/<uuid>; scoping to a namespace is done
  # with the s3tables:namespace condition key, not the resource path.
  tables_arn = "${var.table_bucket_arn}/table/*"
}

resource "aws_s3tables_namespace" "preview" {
  namespace        = local.namespace
  table_bucket_arn = var.table_bucket_arn
}

# A namespace can only be deleted empty, and the preview's migrations create
# its tables outside tofu: drop them just before the namespace goes, or the
# destroy fails and the preview leaks. Uses the destroying identity (the
# preview role may drop tables in preview namespaces only: aws/bootstrap).
resource "terraform_data" "drop_tables" {
  count = var.drop_tables_on_destroy ? 1 : 0

  input = {
    table_bucket_arn = aws_s3tables_namespace.preview.table_bucket_arn
    namespace        = aws_s3tables_namespace.preview.namespace
    region           = element(split(":", var.table_bucket_arn), 3)
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      tables=$(aws s3tables list-tables --region "$REGION" --table-bucket-arn "$BUCKET" --namespace "$NS" --query 'tables[].name' --output text)
      for t in $tables; do
        [ "$t" = "None" ] && continue
        echo "dropping $NS.$t"
        aws s3tables delete-table --region "$REGION" --table-bucket-arn "$BUCKET" --namespace "$NS" --name "$t"
      done
    EOT
    environment = {
      BUCKET = self.input.table_bucket_arn
      NS     = self.input.namespace
      REGION = self.input.region
    }
  }
}

# ------------------------------------------------------------------------------
# Read/write inside the preview namespace only
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "readwrite" {
  statement {
    sid = "BucketDiscovery"
    actions = [
      "s3tables:GetTableBucket",
      "s3tables:GetNamespace",
      "s3tables:ListNamespaces",
      "s3tables:ListTables",
    ]
    resources = [var.table_bucket_arn]
  }

  statement {
    sid = "PreviewNamespaceTables"
    actions = [
      "s3tables:CreateTable",
      "s3tables:GetTable",
      "s3tables:RenameTable",
      "s3tables:DeleteTable",
      "s3tables:GetTableData",
      "s3tables:PutTableData",
      "s3tables:GetTableMetadataLocation",
      "s3tables:UpdateTableMetadataLocation",
      "s3tables:GetTableMaintenanceConfiguration",
      "s3tables:PutTableMaintenanceConfiguration",
    ]
    resources = [local.tables_arn]

    condition {
      test     = "StringEquals"
      variable = "s3tables:namespace"
      values   = [local.namespace]
    }
  }
}

resource "aws_iam_policy" "readwrite" {
  name        = "iceberg-${local.namespace}-rw"
  path        = var.iam_path
  description = "Read/write Iceberg tables in the ${local.namespace} preview namespace"
  policy      = data.aws_iam_policy_document.readwrite.json
  tags        = var.tags
}

# ------------------------------------------------------------------------------
# Read-only on selected prod namespaces (optional)
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "read" {
  count = length(var.read_namespaces) > 0 ? 1 : 0

  statement {
    sid = "ProdNamespaceReads"
    actions = [
      "s3tables:GetTable",
      "s3tables:GetTableData",
      "s3tables:GetTableMetadataLocation",
    ]
    resources = [local.tables_arn]

    condition {
      test     = "StringEquals"
      variable = "s3tables:namespace"
      values   = var.read_namespaces
    }
  }
}

resource "aws_iam_policy" "read" {
  count = length(var.read_namespaces) > 0 ? 1 : 0

  name        = "iceberg-${local.namespace}-read"
  path        = var.iam_path
  description = "Read-only Iceberg access to prod namespaces for the ${local.namespace} preview"
  policy      = data.aws_iam_policy_document.read[0].json
  tags        = var.tags
}
