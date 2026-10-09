/**
 * The role behind SRE Agent's IAM hygiene connector (type `aws_iam`).
 *
 * Self-healing's Security area deactivates an IAM access key that has not been
 * used for 90 days through this role, and can put it back. It is the only place
 * the product writes to IAM, and the grant is as narrow as that write can be.
 */

data "aws_caller_identity" "current" {}

locals {
  # The connector reads a user's keys before it changes one, and refuses a key
  # the user does not hold.
  read_actions = [
    "iam:GetUser",
    "iam:ListAccessKeys",
    "iam:GetAccessKeyLastUsed",
  ]

  # `UpdateAccessKey` only sets a key Active or Inactive. There is no delete,
  # no create, and nothing that touches a user, a policy or a login.
  write_actions = var.enable_key_changes ? ["iam:UpdateAccessKey"] : []

  # IAM is global, so the account is the only scope that exists: every user in
  # it. A key whose user lives in another account is refused by the connector.
  user_arns = ["arn:${var.aws_partition}:iam::${data.aws_caller_identity.current.account_id}:user/*"]
}

data "aws_iam_policy_document" "hygiene" {
  statement {
    sid       = "KeyHygiene"
    effect    = "Allow"
    actions   = sort(concat(local.read_actions, local.write_actions))
    resources = local.user_arns
  }

  # The one statement here that names this role itself: it can simulate only
  # the role it rides on, so the product's Verify button can check this role
  # against what the app derived without a single write. Refuse it and only
  # the verification stops working.
  dynamic "statement" {
    for_each = var.enable_verification ? [1] : []

    content {
      sid       = "Verification"
      effect    = "Allow"
      actions   = ["iam:SimulatePrincipalPolicy"]
      resources = [aws_iam_role.this.arn]
    }
  }
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.trusted_principal_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }
}

# Its own role on purpose, apart from the read-only and the remediation ones:
# no read of your account (the capacity, FinOps and security pages, the
# inventory sweep, the IAM scan) ever uses this credential, and revoking it
# costs nothing but the key action.
resource "aws_iam_role" "this" {
  name                 = var.role_name
  description          = "IAM access key hygiene for SRE Agent (${var.external_id})"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

resource "aws_iam_policy" "this" {
  name        = var.policy_name
  description = "What SRE Agent may do to IAM access keys in this account"
  policy      = data.aws_iam_policy_document.hygiene.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}
