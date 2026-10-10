/**
 * Read-only AWS access for SRE Agent.
 *
 * Broad by design: better FinOps estimates, better capacity planning, and
 * better correlation during an investigation all come from seeing more of the
 * account, not less. You cannot tell whether a volume is waste without knowing
 * what it is attached to, and you cannot tie an incident to a change without
 * seeing both.
 *
 * ## The line this policy draws
 *
 * **Control plane, not data plane.** SRE Agent reads the *shape* of your
 * infrastructure: what exists, how it is configured, what it costs, what
 * changed. Never the data inside it.
 *
 * So this grants `s3:ListBucket` and `s3:GetBucketTagging` but not
 * `s3:GetObject`; `dynamodb:DescribeTable` but not `GetItem`, `Query` or
 * `Scan`; `kinesis:DescribeStream` but not `GetRecords`;
 * `secretsmanager:DescribeSecret` but not `GetSecretValue`;
 * `ssm:DescribeParameters` but not `GetParameter`.
 *
 * That is deliberately a different line from AWS's own `ReadOnlyAccess` managed
 * policy, which *does* include `s3:Get*` and `dynamodb:GetItem` and would let
 * this role read your customers' data. If you were about to reach for
 * `ReadOnlyAccess` because it is easier, that is the reason not to.
 *
 * Everything here is read-only: nothing can create, modify or delete.
 */

locals {
  # Grouped rather than one toggle per service: at this breadth a per-service
  # list is unreviewable, and the groups match how people actually reason about
  # what they are willing to expose.
  statements = {
    # --- Compute -----------------------------------------------------------
    # Instances, EBS volumes, EIPs, snapshots, AMIs, security groups, subnets
    # and VPCs all arrive via ec2:Describe*. Capacity planning and most FinOps
    # waste detectors are built on this group.
    compute = {
      enabled = var.enable_compute
      actions = [
        "ec2:Describe*",
        # Get*, not Describe*: the account's EBS encryption-by-default bit,
        # read by the compliance posture scan for encryption evidence.
        "ec2:GetEbsEncryptionByDefault",
        "autoscaling:Describe*",
        "ecs:List*",
        "ecs:Describe*",
        "eks:List*",
        "eks:Describe*",
        "lambda:List*",
        "lambda:Get*",
        "elasticbeanstalk:Describe*",
        "elasticbeanstalk:List*",
        "batch:Describe*",
        "batch:List*",
      ]
    }

    # --- Storage -----------------------------------------------------------
    # Bucket and filesystem *configuration*: class, lifecycle, tags, versioning.
    # This is what turns "you have 400 buckets" into "this one has no lifecycle
    # rule and is costing you".
    #
    # Excludes s3:GetObject. Listing a bucket's keys is included because
    # inventory needs it; reading their contents is not.
    storage = {
      enabled = var.enable_storage
      actions = [
        "s3:ListAllMyBuckets",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketTagging",
        "s3:GetBucketVersioning",
        "s3:GetBucketPublicAccessBlock",
        "s3:GetLifecycleConfiguration",
        "s3:GetEncryptionConfiguration",
        "s3:GetIntelligentTieringConfiguration",
        "s3:GetStorageLensConfiguration",
        "elasticfilesystem:Describe*",
        "fsx:Describe*",
        "fsx:List*",
        "backup:Describe*",
        "backup:List*",
      ]
    }

    # --- Databases ---------------------------------------------------------
    # Metadata, configuration and sizing. DescribeTable tells you a table's
    # capacity mode; GetItem would tell you what is in it, so it is absent.
    databases = {
      enabled = var.enable_databases
      actions = [
        "rds:Describe*",
        "rds:List*",
        "dynamodb:DescribeTable",
        "dynamodb:DescribeTimeToLive",
        "dynamodb:DescribeContinuousBackups",
        "dynamodb:DescribeGlobalTable",
        "dynamodb:DescribeLimits",
        "dynamodb:ListTables",
        "dynamodb:ListTagsOfResource",
        "dynamodb:ListGlobalTables",
        "dynamodb:ListBackups",
        "elasticache:Describe*",
        "elasticache:List*",
        "redshift:Describe*",
        "memorydb:Describe*",
      ]
    }

    # --- Streaming and messaging -------------------------------------------
    # Stream and queue shape, not payloads: DescribeStream but not GetRecords,
    # GetQueueAttributes but not ReceiveMessage.
    streaming = {
      enabled = var.enable_streaming
      actions = [
        "kinesis:DescribeStream",
        "kinesis:DescribeStreamSummary",
        "kinesis:DescribeLimits",
        "kinesis:ListStreams",
        "kinesis:ListShards",
        "kinesis:ListTagsForStream",
        "firehose:DescribeDeliveryStream",
        "firehose:ListDeliveryStreams",
        "firehose:ListTagsForDeliveryStream",
        "sqs:GetQueueAttributes",
        "sqs:ListQueues",
        "sqs:ListQueueTags",
        "sns:GetTopicAttributes",
        "sns:GetSubscriptionAttributes",
        "sns:List*",
        "kafka:Describe*",
        "kafka:List*",
        "events:Describe*",
        "events:List*",
      ]
    }

    # --- Networking --------------------------------------------------------
    # How traffic reaches a workload, and where "the service is down" is usually
    # first visible. VPC, subnet and security-group detail arrives via
    # ec2:Describe* in the compute group.
    #
    # ACM sits here because a certificate is TLS termination for the load
    # balancers, CloudFront distributions and API Gateways in this same group,
    # and an expiring one takes them all down together. Describe and List only:
    # acm:GetCertificate and acm:ExportCertificate are deliberately absent,
    # because Export hands back the private key of an exportable certificate,
    # which is data rather than shape.
    networking = {
      enabled = var.enable_networking
      actions = [
        "acm:DescribeCertificate",
        "acm:ListCertificates",
        "acm:ListTagsForCertificate",
        "elasticloadbalancing:Describe*",
        "route53:Get*",
        "route53:List*",
        "route53resolver:Get*",
        "route53resolver:List*",
        "cloudfront:Get*",
        "cloudfront:List*",
        "directconnect:Describe*",
        "globalaccelerator:Describe*",
        "globalaccelerator:List*",
      ]
    }

    # --- Observability -----------------------------------------------------
    # Metrics, logs, traces, and the change history an investigation correlates
    # against. logs:StopQuery is write-shaped but only cancels a query this role
    # started.
    observability = {
      enabled = var.enable_observability
      actions = [
        "cloudwatch:Describe*",
        "cloudwatch:Get*",
        "cloudwatch:List*",
        "logs:Describe*",
        "logs:Get*",
        "logs:List*",
        "logs:FilterLogEvents",
        "logs:StartQuery",
        "logs:StopQuery",
        "xray:Get*",
        "xray:BatchGet*",
        "cloudtrail:LookupEvents",
        "cloudtrail:Describe*",
        "cloudtrail:Get*",
        "health:Describe*",
        "applicationinsights:Describe*",
        "applicationinsights:List*",
      ]
    }

    # --- Cost --------------------------------------------------------------
    # What things actually cost, rather than what a price list says they cost.
    # Compute Optimizer is AWS's own rightsizing analysis, which is stronger
    # evidence than inferring from CPU alone.
    #
    # Note that ce: and pricing: calls are themselves billed per request.
    cost = {
      enabled = var.enable_cost
      actions = [
        "ce:Get*",
        "ce:Describe*",
        "ce:List*",
        "budgets:Describe*",
        "budgets:View*",
        "cur:Describe*",
        "pricing:Get*",
        "pricing:Describe*",
        "savingsplans:Describe*",
        "savingsplans:List*",
        "compute-optimizer:Get*",
        "compute-optimizer:Describe*",
        "cost-optimization-hub:Get*",
        "cost-optimization-hub:List*",
      ]
    }

    # --- Ownership and governance ------------------------------------------
    # The tagging API resolves ownership across every service at once, instead
    # of asking each one separately and missing whatever neither side knows.
    governance = {
      enabled = var.enable_governance
      actions = [
        "tag:GetResources",
        "tag:GetTagKeys",
        "tag:GetTagValues",
        "resource-groups:Get*",
        "resource-groups:List*",
        "config:Describe*",
        "config:Get*",
        "config:List*",
        "organizations:Describe*",
        "organizations:List*",
        "servicequotas:Get*",
        "servicequotas:List*",
        "sts:GetCallerIdentity",
      ]
    }

    # --- Identity ----------------------------------------------------------
    # Turns a CloudTrail entry from "some principal" into "this role", which is
    # the difference between a timeline and an explanation.
    #
    # Exposes your principal inventory (names, policies, last-used), though no
    # credentials. Separate toggle for anyone who would rather it did not.
    #
    # GenerateCredentialReport and the sso/identitystore reads joined in v2.3
    # for the compliance posture scan: the credential report carries key ages
    # and MFA facts (never secrets), and Identity Center is how "who can reach
    # this account" gets answered when people arrive through SSO rather than
    # as IAM users. The Generate* verbs here only compute reports.
    identity = {
      enabled = var.enable_identity_read
      actions = [
        "iam:Get*",
        "iam:List*",
        "iam:GenerateServiceLastAccessedDetails",
        "iam:GenerateCredentialReport",
        "sso:Describe*",
        "sso:List*",
        "identitystore:Describe*",
        "identitystore:List*",
      ]
    }

    # --- Inventory ---------------------------------------------------------
    # Existence and configuration of things the groups above do not name, so a
    # service nobody thought of still shows up.
    inventory = {
      enabled = var.enable_inventory
      actions = [
        "ssm:DescribeInstanceInformation",
        "ssm:DescribeParameters",
        "ssm:ListTagsForResource",
        "ssm:GetInventory",
        "ssm:GetInventorySchema",
        "secretsmanager:ListSecrets",
        "secretsmanager:DescribeSecret",
        "ecr:Describe*",
        "ecr:List*",
        "ecr:GetLifecyclePolicy",
        "states:Describe*",
        "states:List*",
      ]
    }

    # --- Bedrock (not read-only) -------------------------------------------
    # Only if you point SRE Agent's AI provider at Bedrock in your own account.
    # Off by default: InvokeModel bills you directly, and most deployments use
    # the platform's configured provider.
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
# operator who disabled every group has almost certainly misread the variables,
# and a role with an empty policy fails later as opaque AccessDenied errors
# inside the product.
resource "terraform_data" "at_least_one_service" {
  lifecycle {
    precondition {
      condition     = length(local.enabled_statements) > 0
      error_message = "At least one service group must be enabled, otherwise this role grants nothing."
    }
  }
}

data "aws_iam_policy_document" "readonly" {
  # Named iterator purely for readability: the default would also be called
  # `statement`, which reads as if the block were referring to itself.
  dynamic "statement" {
    for_each = local.enabled_statements
    iterator = group

    content {
      sid       = title(group.key)
      effect    = "Allow"
      actions   = group.value.actions
      resources = ["*"]
    }
  }

  # Outside the group map because it is the one statement here that is NOT
  # resource "*": it can simulate only the role it rides on, so the product's
  # Verify button can check this role against what the app derived without a
  # single write. Its own toggle for the same reason the groups have theirs;
  # refuse it and only the verification stops working.
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

    # The ExternalId is what stops the confused deputy: without it, anyone who
    # learns your role ARN and can get the platform to call AssumeRole on their
    # behalf reaches your account. SRE Agent generates one per organization;
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
  description = "Read access SRE Agent uses to inspect this account (control plane only)"
  policy      = data.aws_iam_policy_document.readonly.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}
