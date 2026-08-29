/**
 * Opt-in remediation access for SRE Agent.
 *
 * This grants `ssm:SendCommand`, which is arbitrary command execution on the
 * instances it covers. Read the README before applying it.
 */

locals {
  # Scoping by tag is the difference between "SRE Agent can run commands on the
  # instances you nominated" and "on everything in the account". The default
  # requires an opt-in tag rather than allowing "*", so forgetting to scope
  # fails closed.
  instance_conditions = [
    for key, values in var.target_instance_tags : {
      test     = "StringEquals"
      variable = "ssm:resourceTag/${key}"
      values   = values
    }
  ]

  document_arns = [
    for name in var.allowed_documents :
    "arn:${var.aws_partition}:ssm:${var.aws_region}::document/${name}"
  ]
}

data "aws_caller_identity" "current" {}

# A tagless grant would cover every managed instance in the account. Refuse at
# plan time rather than discovering it in an audit.
resource "terraform_data" "requires_scoping" {
  lifecycle {
    precondition {
      condition     = length(var.target_instance_tags) > 0 || var.i_understand_this_covers_every_instance
      error_message = <<-EOT
        target_instance_tags is empty, which would let SRE Agent run commands on
        EVERY SSM-managed instance in this account.

        Either scope it (recommended):
            target_instance_tags = { "sre-agent-remediation" = ["true"] }

        or, if that is genuinely what you want, set
        i_understand_this_covers_every_instance = true.
      EOT
    }
  }
}

data "aws_iam_policy_document" "remediation" {
  # The command itself, narrowed on two axes: which instances, and which
  # documents. AWS-RunShellScript is arbitrary shell, so an operator who wants
  # a genuinely bounded grant should replace it with their own document.
  statement {
    sid       = "SendCommandToInstances"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${var.aws_partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    dynamic "condition" {
      for_each = local.instance_conditions

      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
    }
  }

  statement {
    sid       = "SendCommandWithDocuments"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = local.document_arns
  }

  # Reading back what a command did. Without these the product can start work
  # it cannot report the result of, which is worse than not starting it.
  statement {
    sid    = "ReadCommandResults"
    effect = "Allow"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:ListCommands",
    ]
    resources = ["*"]
  }

  # So the product can tell "the instance is offline" from "the command failed",
  # which are different incidents.
  statement {
    sid       = "DescribeManagedInstances"
    effect    = "Allow"
    actions   = ["ssm:DescribeInstanceInformation"]
    resources = ["*"]
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

# A separate role from the read-only one on purpose. Revoking remediation should
# not mean losing observability, and the two want different review cadences.
resource "aws_iam_role" "this" {
  name                 = var.role_name
  description          = "Remediation (ssm:SendCommand) for SRE Agent (${var.external_id})"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

resource "aws_iam_policy" "this" {
  name        = var.policy_name
  description = "Command execution SRE Agent may perform in this account"
  policy      = data.aws_iam_policy_document.remediation.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}
