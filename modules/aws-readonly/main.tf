/**
 * Read-only AWS access for SRE Agent.
 *
 * Creates the role SRE Agent assumes to read your account, and a policy
 * covering the workload surface it inspects.
 *
 * Scope note: this is deliberately the *service-wide read surface* rather than
 * the exact list of API calls the product makes today. Two reasons. A policy
 * pinned to today's call list needs re-applying every time a feature ships,
 * and the failure when it is stale is silent — a missing permission and "there
 * is nothing to report" render identically in this product. Read access to
 * describe/list operations on compute, observability and tagging is also the
 * grant most organisations already model as low risk.
 *
 * Every statement is still read-only: nothing here can create, modify or
 * delete. Toggle off any service you do not want inspected.
 */

locals {
  # Each block names the feature it powers. `Describe*`/`List*`/`Get*` mirrors
  # how AWS's own ReadOnlyAccess policies are shaped, so it is a familiar grant
  # to review.
  statements = {
    # Instances, volumes, elastic IPs, snapshots, AMIs, security groups,
    # subnets, VPCs. Capacity planning and every FinOps waste detector.
    ec2 = {
      enabled = var.enable_ec2
      actions = ["ec2:Describe*"]
    }

    # Auto Scaling groups: the thing that actually decides how many instances a
    # workload has, so capacity without it is a snapshot rather than a trend.
    autoscaling = {
      enabled = var.enable_autoscaling
      actions = [
        "autoscaling:Describe*",
      ]
    }

    ecs = {
      enabled = var.enable_ecs
      actions = [
        "ecs:List*",
        "ecs:Describe*",
      ]
    }

    # EKS cluster metadata. Note this is the AWS-side view (cluster, nodegroups,
    # versions); reading what runs *inside* the cluster needs the
    # kubernetes-rbac module as well, since EKS authorises that separately
    # through the cluster's own RBAC.
    eks = {
      enabled = var.enable_eks
      actions = [
        "eks:List*",
        "eks:Describe*",
      ]
    }

    lambda = {
      enabled = var.enable_lambda
      actions = [
        "lambda:List*",
        "lambda:Get*",
      ]
    }

    # Load balancers and target groups: where "the service is down" is usually
    # first visible, and how a workload maps to the traffic reaching it.
    elb = {
      enabled = var.enable_load_balancing
      actions = [
        "elasticloadbalancing:Describe*",
      ]
    }

    # Managed data stores a workload depends on. Metadata and configuration
    # only — no data-plane access exists in these actions.
    databases = {
      enabled = var.enable_databases
      actions = [
        "rds:Describe*",
        "rds:List*",
        "elasticache:Describe*",
        "elasticache:List*",
      ]
    }

    # Metrics for SLIs, capacity utilization and the idle-resource detectors,
    # plus alarm state for correlation during an investigation.
    cloudwatch = {
      enabled = var.enable_cloudwatch
      actions = [
        "cloudwatch:Describe*",
        "cloudwatch:Get*",
        "cloudwatch:List*",
      ]
    }

    # Log search during investigations, including Insights queries. StopQuery
    # is a write-shaped action that only cancels a query this role started.
    logs = {
      enabled = var.enable_logs
      actions = [
        "logs:Describe*",
        "logs:Get*",
        "logs:List*",
        "logs:FilterLogEvents",
        "logs:StartQuery",
        "logs:StopQuery",
      ]
    }

    # "Who changed what" during an investigation.
    cloudtrail = {
      enabled = var.enable_cloudtrail
      actions = [
        "cloudtrail:LookupEvents",
        "cloudtrail:Describe*",
        "cloudtrail:Get*",
      ]
    }

    xray = {
      enabled = var.enable_xray
      actions = [
        "xray:Get*",
        "xray:BatchGet*",
      ]
    }

    # The tagging API resolves ownership across every service at once. Without
    # it, deriving an owner means asking each service separately and missing
    # anything neither module knows about.
    tagging = {
      enabled = var.enable_tagging
      actions = [
        "tag:GetResources",
        "tag:GetTagKeys",
        "tag:GetTagValues",
      ]
    }

    # Only if you point SRE Agent's AI provider at Bedrock in your own account.
    # Off by default: this is the one block that is not read-only (InvokeModel
    # bills you directly), and most deployments use the platform's provider.
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
  # Named iterator purely for readability: the default would also be called
  # `statement`, which reads as if the block were referring to itself.
  dynamic "statement" {
    for_each = local.enabled_statements
    iterator = svc

    content {
      sid       = title(svc.key)
      effect    = "Allow"
      actions   = svc.value.actions
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
  description = "Read access SRE Agent uses to inspect workloads in this account"
  policy      = data.aws_iam_policy_document.readonly.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}
