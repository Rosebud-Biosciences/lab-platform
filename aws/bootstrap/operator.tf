# ------------------------------------------------------------------------------
# HUMAN OPERATOR: MFA-GATED ADMIN ROLE + GUARDRAIL POLICY
#
# The CI roles in oidc.tf cover machines. This covers the person who runs
# `tofu apply` by hand -- usually from an IAM user with a long-lived access key,
# which is the credential most likely to leak and the one no MFA condition can
# ever be satisfied by (long-lived keys carry no MFA context at all).
#
# The shape, and why:
#
#   * The static identity keeps only what it needs to *step up*: sts:AssumeRole
#     on this role. Everything it used to do directly moves behind the role.
#   * The role's trust policy requires a recent MFA challenge. This is the only
#     place an MFA condition works for a role: STS drops all MFA context when it
#     mints the role session, so `aws:MultiFactorAuthPresent` is absent from
#     every call made with the role's credentials (IAM User Guide,
#     id_credentials_mfa_configure-api-require). Do not try to gate individual
#     actions on it inside the role's permission policies -- see the guardrail
#     below for how that fails.
#   * A guardrail Deny policy protects the things whose loss is unrecoverable:
#     the state bucket's history, the lock table, the audit trail, and the
#     role/guardrail themselves. It is attached to the role here; attach it to
#     the static identity too (`operator_guardrails_policy_arn`) so a leaked key
#     cannot undo the arrangement.
#
# What to attach for permissions is deliberately the caller's choice
# (`operator_admin_policy_arns`, AdministratorAccess by default). The security
# win is the trust policy, the session bound, and the guardrail -- not the
# allow-list. Scope it down once you know what your stacks actually call.
#
# The module never manages IAM users or group membership; pass the ARNs.
# ------------------------------------------------------------------------------

locals {
  operator_guardrails_policy_name = "${var.operator_admin_role_name}-guardrails"

  # Built by name rather than referenced, so the guardrail can protect itself
  # without a resource cycle (the policy attaches to the role; the document
  # names the policy).
  operator_role_arn              = "arn:aws:iam::${local.account_id}:role/${var.operator_admin_role_name}"
  operator_guardrails_policy_arn = "arn:aws:iam::${local.account_id}:policy/${local.operator_guardrails_policy_name}"
  operator_admin_policy_arns_set = toset(var.operator_admin_policy_arns)
  operator_self_protected_arns   = [local.operator_role_arn, local.operator_guardrails_policy_arn]
}

# --- Trust policy -------------------------------------------------------------

data "aws_iam_policy_document" "operator_assume" {
  count = var.enable_operator_admin_role ? 1 : 0

  statement {
    sid     = "AssumeWithRecentMfa"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.operator_principal_arns
    }

    # Both required. Bool alone lets any MFA'd session -- however old -- step up;
    # the age bound means the CLI re-prompts once its cached session ages out.
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }

    condition {
      test     = "NumericLessThan"
      variable = "aws:MultiFactorAuthAge"
      values   = [tostring(var.operator_mfa_max_age)]
    }
  }
}

resource "aws_iam_role" "operator_admin" {
  count = var.enable_operator_admin_role ? 1 : 0

  name                 = var.operator_admin_role_name
  description          = "Operator role for tofu applies; assumable only with a recent MFA challenge"
  assume_role_policy   = data.aws_iam_policy_document.operator_assume[0].json
  max_session_duration = var.operator_admin_session_duration
  tags                 = var.tags

  lifecycle {
    precondition {
      condition     = length(var.operator_principal_arns) > 0
      error_message = "enable_operator_admin_role requires at least one ARN in operator_principal_arns; a role nobody may assume is not useful."
    }
  }
}

resource "aws_iam_role_policy_attachment" "operator_admin" {
  for_each = var.enable_operator_admin_role ? local.operator_admin_policy_arns_set : toset([])

  role       = aws_iam_role.operator_admin[0].name
  policy_arn = each.value
}

# --- Guardrails ---------------------------------------------------------------
#
# Explicit Deny beats every Allow, including AdministratorAccess, so this holds
# no matter what the caller attaches above.
#
# Two kinds of statement. The unconditional ones cover actions no module in this
# family performs during normal operation, so they bind the role as well as the
# static key; undoing one is a deliberate two-step (edit the guardrail, apply,
# then act). The conditional ones cover actions bootstrap itself performs when
# its inputs change (the state bucket policy, versioning, the lock table's
# deletion protection, its own IAM objects); those exempt the role so a
# role-run apply still works, and bind only a caller that is neither the role
# nor an MFA-backed session -- which is to say, the static key.

data "aws_iam_policy_document" "operator_guardrails" {
  count = var.enable_operator_admin_role ? 1 : 0

  # Terraform never deletes the bucket that holds its own state, and never
  # deletes object versions: that is state history, and it is the only undo
  # there is. The bucket policy in main.tf already denies DeleteBucket to
  # every principal; this is the layer that survives that policy being removed.
  statement {
    sid    = "ProtectStateHistory"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:DeleteObjectVersion",
    ]
    resources = [
      local.state_bucket_arn,
      "${local.state_bucket_arn}/*",
    ]
  }

  # Native deletion protection stops a stray `destroy`; this stops the
  # principal that could turn deletion protection off.
  statement {
    sid       = "ProtectLockTable"
    effect    = "Deny"
    actions   = ["dynamodb:DeleteTable"]
    resources = [local.lock_table_arn]
  }

  # No module here manages a trail, so every mutating CloudTrail call is either
  # a mistake or someone erasing the record of what they just did.
  statement {
    sid    = "ProtectAuditTrail"
    effect = "Deny"
    actions = [
      "cloudtrail:DeleteEventDataStore",
      "cloudtrail:DeleteTrail",
      "cloudtrail:PutEventSelectors",
      "cloudtrail:StopLogging",
      "cloudtrail:UpdateEventDataStore",
      "cloudtrail:UpdateTrail",
    ]
    resources = ["*"]
  }

  # The guards bootstrap manages: the state bucket's Deny policy and versioning,
  # and the lock table's deletion-protection flag. bootstrap changes these when
  # its inputs change, so the role stays able to; the static key does not.
  statement {
    sid    = "ProtectStateGuardsFromStaticKey"
    effect = "Deny"
    actions = [
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutLifecycleConfiguration",
    ]
    resources = [local.state_bucket_arn]

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [local.operator_role_arn]
    }
    condition {
      test     = "BoolIfExists"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["false"]
    }
  }

  statement {
    sid       = "ProtectLockTableGuardFromStaticKey"
    effect    = "Deny"
    actions   = ["dynamodb:UpdateTable"]
    resources = [local.lock_table_arn]

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [local.operator_role_arn]
    }
    condition {
      test     = "BoolIfExists"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["false"]
    }
  }

  # Self-protection. Without this, anything holding IAMFullAccess (or the
  # AdministratorAccess default above, if it were attached to the key) could
  # detach the guardrail, or edit the MFA condition out of the trust policy,
  # and carry on. Only weakening actions are listed; Attach/Put are absent
  # because granting *more* cannot get around a Deny, and denying them would
  # race the apply that attaches these very policies.
  #
  # The two conditions are ANDed. The MFA test cannot stand alone: a role
  # session never carries the key (see the header), so BoolIfExists "false"
  # would match the role exactly as it matches a bare access key and lock out
  # the one principal meant to get through. The principal test exempts the
  # role by identity -- aws:PrincipalArn on an assumed-role request is the
  # role's ARN, not the session's. The MFA test stays so that a GetSessionToken
  # session minted with MFA (the operator's own principal, but with
  # MultiFactorAuthPresent=true) can still get through as break-glass.
  statement {
    sid    = "ProtectOwnPermissionsFromStaticKey"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:SetDefaultPolicyVersion",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
    ]
    resources = local.operator_self_protected_arns

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [local.operator_role_arn]
    }
    condition {
      test     = "BoolIfExists"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["false"]
    }
  }
}

resource "aws_iam_policy" "operator_guardrails" {
  count = var.enable_operator_admin_role ? 1 : 0

  name        = local.operator_guardrails_policy_name
  description = "Denies state-history and lock-table destruction, CloudTrail tampering, and edits to the operator role from anything but the role or an MFA session"
  policy      = data.aws_iam_policy_document.operator_guardrails[0].json
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "operator_guardrails" {
  count = var.enable_operator_admin_role ? 1 : 0

  role       = aws_iam_role.operator_admin[0].name
  policy_arn = aws_iam_policy.operator_guardrails[0].arn
}
