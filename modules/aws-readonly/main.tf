/**
 * Read-only AWS access for SRE Agent.
 *
 * Creates the role SRE Agent assumes to read your account, and a policy
 * containing exactly the actions the product calls — no more.
 */

locals {
  # Every action below corresponds to a call the product actually makes. Adding
  # a service here without a corresponding call is how a "read-only" policy
  # quietly becomes a broad one, so each block names the feature that needs it.
  statements = {
    # Capacity planning and the FinOps waste detectors (instances, volumes,
    # elastic IPs, snapshots, AMIs).
    ec2 = {
      enabled = var.enable_ec2
      actions = [
        "ec2:DescribeInstances",
        "ec2:DescribeVolumes",
        "ec2:DescribeAddresses",
        "ec2:DescribeSnapshots",
        "ec2:DescribeImages",
      ]
    }

    # Metrics for SLIs, capacity utilization and the idle-resource detectors,
    # plus alarm state for correlation during an investigation.
    cloudwatch = {
      enabled = var.enable_cloudwatch
      actions = [
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:GetMetricData",
        "cloudwatch:ListMetrics",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:DescribeAlarmHistory",
      ]
    }

    # Log search during investigations, including Insights queries.
    logs = {
      enabled = var.enable_logs
      actions = [
        "logs:DescribeLogGroups",
        "logs:FilterLogEvents",
        "logs:GetLogEvents",
        "logs:StartQuery",
        "logs:GetQueryResults",
      ]
    }

    ecs = {
      enabled = var.enable_ecs
      actions = [
        "ecs:ListClusters",
        "ecs:ListServices",
        "ecs:DescribeServices",
        "ecs:ListTasks",
      ]
    }

    lambda = {
      enabled = var.enable_lambda
      actions = [
        "lambda:ListFunctions",
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
      ]
    }

    # "Who changed what" during an investigation.
    cloudtrail = {
      enabled = var.enable_cloudtrail
      actions = ["cloudtrail:LookupEvents"]
    }

    xray = {
      enabled = var.enable_xray
      actions = [
        "xray:GetTraceSummaries",
        "xray:BatchGetTraces",
      ]
    }

    # Only if you point SRE Agent's AI provider at Bedrock in your own account.
    # Off by default: most deployments use the platform's provider instead, and
    # InvokeModel bills you directly.
    bedrock = {
      enabled = var.enable_bedrock
      actions = [
        "bedrock:ListFoundationModels",
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
      ]
    }
  }

  enabled_statements = { for name, s in local.statements : name => s if s.enabled }
}

# Fail during plan rather than handing over a role that grants nothing. An
# operator who disabled every service has almost certainly misread the
# variables, and a role with an empty policy fails later as opaque AccessDenied
# errors inside the product.
resource "terraform_data" "at_least_one_service" {
  lifecycle {
    precondition {
      condition     = length(local.enabled_statements) > 0
      error_message = "At least one service must be enabled, otherwise this role grants nothing."
    }
  }
}

data "aws_iam_policy_document" "readonly" {
  dynamic "statement" {
    for_each = local.enabled_statements

    content {
      sid       = title(statement.key)
      effect    = "Allow"
      actions   = statement.value.actions
      resources = ["*"]
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

    # The ExternalId is what stops the confused deputy: without it, anyone who
    # learns your role ARN and can get the platform to call AssumeRole on their
    # behalf reaches your account. SRE Agent generates one per organization —
    # copy it from the data-source settings page, never invent your own.
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  description          = "Read-only access for SRE Agent (${var.external_id})"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

resource "aws_iam_policy" "this" {
  name        = var.policy_name
  description = "Actions SRE Agent calls when reading this account"
  policy      = data.aws_iam_policy_document.readonly.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}
