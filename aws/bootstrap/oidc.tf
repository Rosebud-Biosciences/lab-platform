# ------------------------------------------------------------------------------
# GITHUB ACTIONS OIDC -> CI + PREVIEW ROLES
# ------------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.github_oidc_provider_arn

  ci_repo_subs      = [for repo in var.ci_repos : "repo:${var.github_owner}/${repo}:*"]
  preview_repo_subs = [for repo in var.preview_repos : "repo:${var.github_owner}/${repo}:*"]

  ci_ecr_repo_arns = [
    for repo in var.ci_ecr_repositories :
    "arn:aws:ecr:${local.region}:${local.account_id}:repository/${repo}"
  ]
  preview_ecr_repo_arns = [
    for repo in var.preview_ecr_repositories :
    "arn:aws:ecr:${local.region}:${local.account_id}:repository/${repo}"
  ]

  cluster_arn_pattern = "arn:aws:eks:${local.region}:${local.account_id}:cluster/${var.cluster_name_pattern}"

  state_bucket_arn = aws_s3_bucket.state.arn
  lock_table_arn   = aws_dynamodb_table.locks.arn

  preview_managed_role_arns   = ["arn:aws:iam::${local.account_id}:role${var.preview_iam_path}*"]
  preview_managed_policy_arns = ["arn:aws:iam::${local.account_id}:policy${var.preview_iam_path}*"]
  preview_bucket_arn          = "arn:aws:s3:::${var.preview_ephemeral_bucket_pattern}"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = var.tags
}

# ------------------------------------------------------------------------------
# CI DEPLOYER ROLE (ECR push + EKS describe)
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "ci_assume" {
  count = var.enable_ci_deployer_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.ci_repo_subs
    }
  }
}

resource "aws_iam_role" "ci_deployer" {
  count = var.enable_ci_deployer_role ? 1 : 0

  name               = var.ci_deployer_role_name
  description        = "Assumed by GitHub Actions to push images and deploy to EKS"
  assume_role_policy = data.aws_iam_policy_document.ci_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "ci_deployer" {
  count = var.enable_ci_deployer_role ? 1 : 0

  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = length(local.ci_ecr_repo_arns) > 0 ? local.ci_ecr_repo_arns : ["arn:aws:ecr:${local.region}:${local.account_id}:repository/*"]
  }

  statement {
    sid       = "EksDescribe"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [local.cluster_arn_pattern]
  }
}

resource "aws_iam_role_policy" "ci_deployer" {
  count = var.enable_ci_deployer_role ? 1 : 0

  name   = var.ci_deployer_role_name
  role   = aws_iam_role.ci_deployer[0].id
  policy = data.aws_iam_policy_document.ci_deployer[0].json
}

# ------------------------------------------------------------------------------
# PREVIEW DEPLOYER ROLE (Terraform state + tightly-scoped IAM/S3/KMS)
#
# Scoped to only what the preview stack touches: its own Terraform state
# (writes limited to preview_state_key_prefix), EKS describe, IAM roles and
# policies under preview_iam_path (roles only with the preview permissions
# boundary), and the ephemeral bucket + its KMS key (KMS mutations gated on the
# preview tag).
# ------------------------------------------------------------------------------

locals {
  preview_attachable_policy_arns = concat(local.preview_managed_policy_arns, var.preview_attachable_policy_arns)

  # The most a preview workload may ever do, whatever its role is given: the
  # union of what the preview stack's modules grant (aws/s3-bucket,
  # aws/data-access, aws/iceberg-branches, aws/data-adapter). No IAM, no STS,
  # no compute, no bucket or key configuration.
  preview_boundary_actions = concat(
    [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketLocation",
      "s3tables:GetTableBucket",
      "s3tables:GetNamespace",
      "s3tables:ListNamespaces",
      "s3tables:ListTables",
      "s3tables:GetTable",
      "s3tables:CreateTable",
      "s3tables:DeleteTable",
      "s3tables:RenameTable",
      "s3tables:GetTableData",
      "s3tables:PutTableData",
      "s3tables:GetTableMetadataLocation",
      "s3tables:UpdateTableMetadataLocation",
      "s3tables:GetTableMaintenanceConfiguration",
      "s3tables:PutTableMaintenanceConfiguration",
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ],
    var.preview_boundary_extra_actions,
  )
}

data "aws_iam_policy_document" "preview_boundary" {
  #checkov:skip=CKV_AWS_356:a permissions boundary grants nothing; it caps the actions of the preview policies it bounds, which name their resources (preview_boundary_resources narrows it further)
  #checkov:skip=CKV_AWS_108:same: object reads are granted, and scoped, by each preview policy; the boundary only caps them
  count = var.enable_preview_deployer_role ? 1 : 0

  statement {
    sid       = "PreviewWorkloads"
    effect    = "Allow"
    actions   = local.preview_boundary_actions
    resources = var.preview_boundary_resources
  }
}

# Outside preview_iam_path, so the preview role cannot edit it.
resource "aws_iam_policy" "preview_boundary" {
  count = var.enable_preview_deployer_role ? 1 : 0

  name        = "${var.preview_deployer_role_name}-workload-boundary"
  description = "Permissions boundary on every IAM role the preview stack creates: the most a preview workload may do"
  policy      = data.aws_iam_policy_document.preview_boundary[0].json
  tags        = var.tags
}

data "aws_iam_policy_document" "preview_assume" {
  count = var.enable_preview_deployer_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.preview_repo_subs
    }
  }
}

resource "aws_iam_role" "preview_deployer" {
  count = var.enable_preview_deployer_role ? 1 : 0

  name               = var.preview_deployer_role_name
  description        = "Assumed by GitHub Actions to run the preview Terraform stack"
  assume_role_policy = data.aws_iam_policy_document.preview_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "preview_deployer" {
  #checkov:skip=CKV_AWS_356:the "*" statements are IAM Get*/List*, kms:CreateKey and its read-backs (no key ARN exists yet), and key mutations gated on the preview tag; every other statement names its resources
  #checkov:skip=CKV_AWS_111:the unconstrained writes are KMS key creation (no ARN yet) and tag-gated key mutations; IAM writes are confined to preview_iam_path and the boundary
  count = var.enable_preview_deployer_role ? 1 : 0

  # --- Terraform remote state ---
  statement {
    sid       = "TfStateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }
  statement {
    sid       = "TfStateRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.state_bucket_arn}/*"]
  }
  statement {
    sid       = "TfStateWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.state_bucket_arn}/${var.preview_state_key_prefix}"]
  }
  statement {
    sid       = "TfLock"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [local.lock_table_arn]
  }

  # --- EKS describe (k8s RBAC comes from an access entry, not here) ---
  statement {
    sid       = "EksDescribe"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [local.cluster_arn_pattern]
  }

  # --- Read-only IAM (resolve bucket policies + the cluster OIDC provider) ---
  statement {
    sid       = "IamReadOnly"
    effect    = "Allow"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # --- Mutating IAM: the preview stack's own roles, under preview_iam_path ---
  # Anyone who can push a branch runs this role (a PR's workflow is its own),
  # so it must not be able to mint more than a preview needs: every role it
  # creates or changes carries the preview boundary, which caps whatever
  # policy the role is given, and it attaches only the stack's own policies.
  statement {
    sid    = "IamRolesUnderBoundary"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = local.preview_managed_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.preview_boundary[0].arn]
    }
  }
  statement {
    sid       = "IamAttachPreviewPolicies"
    effect    = "Allow"
    actions   = ["iam:AttachRolePolicy"]
    resources = local.preview_managed_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.preview_boundary[0].arn]
    }
    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values   = local.preview_attachable_policy_arns
    }
  }
  statement {
    sid    = "IamRolesLifecycle"
    effect = "Allow"
    actions = [
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRoleDescription",
    ]
    resources = local.preview_managed_role_arns
  }

  # --- Mutating IAM: the preview stack's own policies, under preview_iam_path ---
  statement {
    sid    = "IamManagePolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = local.preview_managed_policy_arns
  }

  # --- Ephemeral processed-data S3 bucket (created + torn down per preview) ---
  statement {
    sid    = "EphemeralBucketManage"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:PutBucketTagging",
      "s3:GetBucketTagging",
      "s3:PutEncryptionConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:PutBucketVersioning",
      "s3:GetBucketVersioning",
      "s3:PutBucketOwnershipControls",
      "s3:GetBucketOwnershipControls",
      "s3:PutBucketAcl",
      "s3:GetBucketAcl",
      "s3:PutLifecycleConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:PutBucketPolicy",
      "s3:GetBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutIntelligentTieringConfiguration",
      "s3:GetIntelligentTieringConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      # Read-only probes the provider issues for aws_s3_bucket itself; grant the
      # whole read set so a missing one does not fail the apply after CreateBucket.
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketLogging",
      "s3:GetBucketNotification",
      "s3:GetReplicationConfiguration",
      "s3:GetBucketObjectLockConfiguration",
    ]
    resources = [local.preview_bucket_arn]
  }
  statement {
    sid    = "EphemeralBucketObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]
    resources = ["${local.preview_bucket_arn}/*"]
  }

  # --- KMS key encrypting the ephemeral bucket (own key per preview) ---
  # CreateKey + the immediate read-backs cannot be resource-scoped (no ARN yet),
  # so they stay on "*". Every destructive mutation is gated on the preview tag.
  statement {
    sid    = "EphemeralKmsCreateAndRead"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListResourceTags",
      "kms:EnableKeyRotation",
    ]
    resources = ["*"]
  }
  statement {
    sid    = "EphemeralKmsMutatePreviewKeys"
    effect = "Allow"
    actions = [
      "kms:TagResource",
      "kms:UntagResource",
      "kms:PutKeyPolicy",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${var.preview_resource_tag_key}"
      values   = [var.preview_resource_tag_value]
    }
  }

  # --- Prune a PR's preview images from ECR on teardown (optional) ---
  dynamic "statement" {
    for_each = length(local.preview_ecr_repo_arns) > 0 ? [1] : []
    content {
      sid    = "EcrPrunePreviewImages"
      effect = "Allow"
      actions = [
        "ecr:ListImages",
        "ecr:DescribeImages",
        "ecr:BatchDeleteImage",
      ]
      resources = local.preview_ecr_repo_arns
    }
  }

  # --- Ephemeral Iceberg namespaces in shared S3 Tables buckets (optional) ---
  dynamic "statement" {
    for_each = length(var.preview_table_bucket_arns) > 0 ? [1] : []
    content {
      sid    = "IcebergNamespaceManage"
      effect = "Allow"
      actions = [
        "s3tables:CreateNamespace",
        "s3tables:DeleteNamespace",
        "s3tables:GetNamespace",
        "s3tables:ListNamespaces",
        "s3tables:GetTableBucket",
        "s3tables:ListTables",
      ]
      resources = var.preview_table_bucket_arns
    }
  }
  # Teardown must be able to drop tables the preview's migrations created inside
  # its own namespace (DeleteNamespace requires an empty namespace). Scoped by
  # the namespace pattern so prod namespaces stay untouchable.
  dynamic "statement" {
    for_each = length(var.preview_table_bucket_arns) > 0 ? [1] : []
    content {
      sid    = "IcebergPreviewTableCleanup"
      effect = "Allow"
      actions = [
        "s3tables:GetTable",
        "s3tables:DeleteTable",
      ]
      resources = [for arn in var.preview_table_bucket_arns : "${arn}/table/*"]

      condition {
        test     = "StringLike"
        variable = "s3tables:namespace"
        values   = [var.preview_iceberg_namespace_pattern]
      }
    }
  }
}

resource "aws_iam_role_policy" "preview_deployer" {
  count = var.enable_preview_deployer_role ? 1 : 0

  name   = var.preview_deployer_role_name
  role   = aws_iam_role.preview_deployer[0].id
  policy = data.aws_iam_policy_document.preview_deployer[0].json
}
