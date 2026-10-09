/**
 * The role behind SRE Agent's AWS cleanup connector (type `aws_cleanup`).
 *
 * Self-healing's deletions go through this role and no other: an IAM access key it
 * deactivated 30 days earlier, a console password nobody uses, an unattached EBS volume
 * (after a snapshot), an unassociated Elastic IP, an old snapshot or an unused image
 * (while a Recycle Bin rule keeps them), and the retention you choose on a log group that
 * never expires. Deleting this role is the AWS-side kill switch for every one of them.
 *
 * Allow statements carry no Condition, with one exception: `ec2:CreateTags` is allowed
 * only while a snapshot or volume is created, so the role cannot tag existing resources.
 * The product's Verify button passes that context when it simulates. The other Condition
 * is on the Deny at the end: every destructive write is refused on a resource
 * tagged `sre-agent:protect` (any value), whatever SRE Agent decides.
 */

data "aws_caller_identity" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  arn     = "arn:${var.aws_partition}"

  user_arns  = ["${local.arn}:iam::${local.account}:user/*"]
  group_arns = ["${local.arn}:iam::${local.account}:group/*"]

  volume_arn   = "${local.arn}:ec2:${var.aws_region}:${local.account}:volume/*"
  snapshot_arn = "${local.arn}:ec2:${var.aws_region}::snapshot/*"
  image_arn    = "${local.arn}:ec2:${var.aws_region}::image/*"
  address_arn  = "${local.arn}:ec2:${var.aws_region}:${local.account}:elastic-ip/*"
  log_arn      = "${local.arn}:logs:${var.aws_region}:${local.account}:log-group:*:*"
  rule_arn     = "${local.arn}:rbin:${var.aws_region}:${local.account}:rule/*"

  # Built from the name rather than read from the role, so the policy document is known at plan
  # time and can be tested without creating anything.
  own_role_arn = "${local.arn}:iam::${local.account}:role/${var.role_name}"

  # Describe and list calls authorize on no resource: AWS requires * for them, so a
  # narrower ARN would read as tighter and be denied.
  any_reads = sort(distinct(concat(
    var.enable_ebs_deletions ? [
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
      "cloudtrail:LookupEvents",
    ] : [],
    var.enable_address_release ? [
      "ec2:DescribeAddresses",
      "ec2:DescribeAddressesAttribute",
    ] : [],
    var.enable_snapshot_image_deletions ? [
      "ec2:DescribeSnapshots",
      "ec2:DescribeSnapshotAttribute",
      "ec2:DescribeImages",
      "ec2:DescribeImageAttribute",
      "ec2:DescribeInstances",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:ListImagesInRecycleBin",
      "ec2:ListSnapshotsInRecycleBin",
      "autoscaling:DescribeLaunchConfigurations",
      "rbin:ListRules",
    ] : [],
    var.enable_log_retention ? [
      "logs:DescribeLogGroups",
      "cloudtrail:DescribeTrails",
    ] : [],
  )))

  iam_user_actions = sort([
    "iam:DeleteAccessKey",
    "iam:DeleteLoginProfile",
    "iam:GetAccessKeyLastUsed",
    "iam:GetLoginProfile",
    "iam:GetUser",
    "iam:GetUserPolicy",
    "iam:ListAccessKeys",
    "iam:ListAttachedUserPolicies",
    "iam:ListGroupsForUser",
    "iam:ListMFADevices",
    "iam:ListUserPolicies",
  ])

  iam_group_actions = sort([
    "iam:GetGroupPolicy",
    "iam:ListAttachedGroupPolicies",
    "iam:ListGroupPolicies",
  ])

  # The destructive writes, and only those: the Deny below covers exactly the ones the
  # role is granted.
  protected_writes = sort(concat(
    var.enable_iam_deletions ? ["iam:DeleteAccessKey", "iam:DeleteLoginProfile"] : [],
    var.enable_ebs_deletions ? ["ec2:DeleteVolume"] : [],
    var.enable_address_release ? ["ec2:ReleaseAddress"] : [],
    var.enable_snapshot_image_deletions ? ["ec2:DeleteSnapshot", "ec2:DeregisterImage"] : [],
    var.enable_log_retention ? ["logs:PutRetentionPolicy"] : [],
  ))
}

data "aws_iam_policy_document" "cleanup" {
  dynamic "statement" {
    for_each = length(local.any_reads) > 0 ? [1] : []

    content {
      sid       = "ReadsThatNameNoResource"
      effect    = "Allow"
      actions   = local.any_reads
      resources = ["*"]
    }
  }

  # Security: delete a key SRE Agent deactivated, and the console password of a user who
  # never added MFA. The reads that prove them unused sit on the same scope.
  dynamic "statement" {
    for_each = var.enable_iam_deletions ? [1] : []

    content {
      sid       = "IamUsers"
      effect    = "Allow"
      actions   = local.iam_user_actions
      resources = local.user_arns
    }
  }

  dynamic "statement" {
    for_each = var.enable_iam_deletions ? [1] : []

    content {
      sid       = "IamGroupPolicyReads"
      effect    = "Allow"
      actions   = local.iam_group_actions
      resources = local.group_arns
    }
  }

  # FinOps: an unattached volume is snapshotted, then deleted, and can be recreated from
  # the snapshot.
  dynamic "statement" {
    for_each = var.enable_ebs_deletions ? [1] : []

    content {
      sid       = "VolumeDelete"
      effect    = "Allow"
      actions   = ["ec2:DeleteVolume"]
      resources = [local.volume_arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_ebs_deletions ? [1] : []

    content {
      sid       = "VolumeSnapshotAndRestore"
      effect    = "Allow"
      actions   = ["ec2:CreateSnapshot", "ec2:CreateVolume"]
      resources = [local.volume_arn, local.snapshot_arn]
    }
  }

  # Tags are written only while a snapshot or a volume is created. Without the condition the
  # role could add any tag to any existing volume or snapshot, which is a way around tag-based
  # access control. This is the one conditioned Allow; the product's Verify button passes the
  # matching `ec2:CreateAction` context when it simulates.
  dynamic "statement" {
    for_each = var.enable_ebs_deletions ? [1] : []

    content {
      sid       = "TagOnCreateOnly"
      effect    = "Allow"
      actions   = ["ec2:CreateTags"]
      resources = [local.volume_arn, local.snapshot_arn]

      condition {
        test     = "StringEquals"
        variable = "ec2:CreateAction"
        values   = ["CreateSnapshot", "CreateVolume"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_address_release ? [1] : []

    content {
      sid       = "AddressRelease"
      effect    = "Allow"
      actions   = ["ec2:ReleaseAddress"]
      resources = [local.address_arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_snapshot_image_deletions ? [1] : []

    content {
      sid       = "ImageDeregisterAndRestore"
      effect    = "Allow"
      actions   = ["ec2:DeregisterImage", "ec2:RestoreImageFromRecycleBin"]
      resources = [local.image_arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_snapshot_image_deletions ? [1] : []

    content {
      sid       = "SnapshotDeleteAndRestore"
      effect    = "Allow"
      actions   = ["ec2:DeleteSnapshot", "ec2:RestoreSnapshotFromRecycleBin"]
      resources = [local.snapshot_arn]
    }
  }

  # The Recycle Bin rules that decide whether a deleted snapshot or image can be restored.
  dynamic "statement" {
    for_each = var.enable_snapshot_image_deletions ? [1] : []

    content {
      sid       = "RecycleBinRules"
      effect    = "Allow"
      actions   = ["rbin:GetRule"]
      resources = [local.rule_arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_log_retention ? [1] : []

    content {
      sid       = "LogRetention"
      effect    = "Allow"
      actions   = ["logs:DeleteRetentionPolicy", "logs:ListTagsForResource", "logs:PutRetentionPolicy"]
      resources = [local.log_arn]
    }
  }

  # The one statement here that names this role itself: it can simulate only the role it
  # rides on, so the product's Verify button can check this role against what the app
  # derived without a single write. Refuse it and only the verification stops working.
  dynamic "statement" {
    for_each = var.enable_verification ? [1] : []

    content {
      sid       = "Verification"
      effect    = "Allow"
      actions   = ["iam:SimulatePrincipalPolicy"]
      resources = [local.own_role_arn]
    }
  }

  # The protect tag: AWS refuses a destructive write on anything tagged `sre-agent:protect`
  # (any value), even if SRE Agent did not. `Null: false` means "the tag key exists".
  dynamic "statement" {
    for_each = length(local.protected_writes) > 0 ? [1] : []

    content {
      sid       = "RefuseProtectedResources"
      effect    = "Deny"
      actions   = local.protected_writes
      resources = ["*"]

      condition {
        test     = "Null"
        variable = "aws:ResourceTag/${var.protect_tag_key}"
        values   = ["false"]
      }
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

# Its own role on purpose, apart from the read-only, the remediation and the IAM hygiene
# ones: no page or scan ever uses this credential (only the checks a deletion makes about
# its own target do, including cloudtrail:LookupEvents), a runbook step can never name it,
# and deleting it stops every deletion SRE Agent could make.
resource "aws_iam_role" "this" {
  name                 = var.role_name
  description          = "Deletions SRE Agent may make in this account (${var.external_id})"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

resource "aws_iam_policy" "this" {
  name        = var.policy_name
  description = "What SRE Agent may delete in this account"
  policy      = data.aws_iam_policy_document.cleanup.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}
