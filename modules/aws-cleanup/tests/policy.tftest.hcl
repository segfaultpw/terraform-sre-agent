# The policy this module writes must grant exactly what the product derives for the cleanup
# role (Settings, Infrastructure, Show the policy), for account 123456789012 in us-east-1 with
# every group on. The expected list below is that derivation, one line per
# "effect|action|resources|condition", so a drift in either side fails here.

# A plan builds the policy documents locally, so no credentials are used or needed.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

variables {
  external_id           = "0123456789abcdef0123"
  trusted_principal_arn = "arn:aws:iam::111122223333:role/sre-agent-platform"
  aws_region            = "us-east-1"
  enable_verification   = false
}

run "grants_what_the_product_derives" {
  command = plan

  assert {
    condition = toset(flatten([
      for s in jsondecode(data.aws_iam_policy_document.cleanup.json).Statement : [
        for a in flatten([s.Action]) :
        "${s.Effect}|${a}|${join(",", sort(flatten([s.Resource])))}|${try(jsonencode(s.Condition), "")}"
      ]
      ])) == toset([
      "Allow|autoscaling:DescribeLaunchConfigurations|*|",
      "Allow|cloudtrail:DescribeTrails|*|",
      "Allow|cloudtrail:LookupEvents|*|",
      "Allow|ec2:CreateSnapshot|arn:aws:ec2:us-east-1:123456789012:volume/*,arn:aws:ec2:us-east-1::snapshot/*|",
      "Allow|ec2:CreateTags|arn:aws:ec2:us-east-1:123456789012:volume/*,arn:aws:ec2:us-east-1::snapshot/*|",
      "Allow|ec2:CreateVolume|arn:aws:ec2:us-east-1:123456789012:volume/*,arn:aws:ec2:us-east-1::snapshot/*|",
      "Allow|ec2:DeleteSnapshot|arn:aws:ec2:us-east-1::snapshot/*|",
      "Allow|ec2:DeleteVolume|arn:aws:ec2:us-east-1:123456789012:volume/*|",
      "Allow|ec2:DeregisterImage|arn:aws:ec2:us-east-1::image/*|",
      "Allow|ec2:DescribeAddresses|*|",
      "Allow|ec2:DescribeAddressesAttribute|*|",
      "Allow|ec2:DescribeImageAttribute|*|",
      "Allow|ec2:DescribeImages|*|",
      "Allow|ec2:DescribeInstances|*|",
      "Allow|ec2:DescribeLaunchTemplateVersions|*|",
      "Allow|ec2:DescribeLaunchTemplates|*|",
      "Allow|ec2:DescribeSnapshotAttribute|*|",
      "Allow|ec2:DescribeSnapshots|*|",
      "Allow|ec2:DescribeVolumes|*|",
      "Allow|ec2:ListImagesInRecycleBin|*|",
      "Allow|ec2:ListSnapshotsInRecycleBin|*|",
      "Allow|ec2:ReleaseAddress|arn:aws:ec2:us-east-1:123456789012:elastic-ip/*|",
      "Allow|ec2:RestoreImageFromRecycleBin|arn:aws:ec2:us-east-1::image/*|",
      "Allow|ec2:RestoreSnapshotFromRecycleBin|arn:aws:ec2:us-east-1::snapshot/*|",
      "Allow|iam:DeleteAccessKey|arn:aws:iam::123456789012:user/*|",
      "Allow|iam:DeleteLoginProfile|arn:aws:iam::123456789012:user/*|",
      "Allow|iam:GetAccessKeyLastUsed|arn:aws:iam::123456789012:user/*|",
      "Allow|iam:GetGroupPolicy|arn:aws:iam::123456789012:group/*|",
      "Allow|iam:GetLoginProfile|arn:aws:iam::123456789012:user/*|",
      "Allow|iam:GetUser|arn:aws:iam::123456789012:user/*|",
      "Allow|iam:GetUserPolicy|arn:aws:iam::123456789012:user/*|",
      "Allow|iam:ListAccessKeys|arn:aws:iam::123456789012:user/*|",
      "Allow|iam:ListAttachedGroupPolicies|arn:aws:iam::123456789012:group/*|",
      "Allow|iam:ListAttachedUserPolicies|arn:aws:iam::123456789012:user/*|",
      "Allow|iam:ListGroupPolicies|arn:aws:iam::123456789012:group/*|",
      "Allow|iam:ListGroupsForUser|arn:aws:iam::123456789012:user/*|",
      "Allow|iam:ListMFADevices|arn:aws:iam::123456789012:user/*|",
      "Allow|iam:ListUserPolicies|arn:aws:iam::123456789012:user/*|",
      "Allow|logs:DeleteRetentionPolicy|arn:aws:logs:us-east-1:123456789012:log-group:*:*|",
      "Allow|logs:DescribeLogGroups|*|",
      "Allow|logs:ListTagsForResource|arn:aws:logs:us-east-1:123456789012:log-group:*:*|",
      "Allow|logs:PutRetentionPolicy|arn:aws:logs:us-east-1:123456789012:log-group:*:*|",
      "Allow|rbin:GetRule|arn:aws:rbin:us-east-1:123456789012:rule/*|",
      "Allow|rbin:ListRules|*|",
      "Deny|ec2:DeleteSnapshot|*|{\"Null\":{\"aws:ResourceTag/sre-agent:protect\":\"false\"}}",
      "Deny|ec2:DeleteVolume|*|{\"Null\":{\"aws:ResourceTag/sre-agent:protect\":\"false\"}}",
      "Deny|ec2:DeregisterImage|*|{\"Null\":{\"aws:ResourceTag/sre-agent:protect\":\"false\"}}",
      "Deny|ec2:ReleaseAddress|*|{\"Null\":{\"aws:ResourceTag/sre-agent:protect\":\"false\"}}",
      "Deny|iam:DeleteAccessKey|*|{\"Null\":{\"aws:ResourceTag/sre-agent:protect\":\"false\"}}",
      "Deny|iam:DeleteLoginProfile|*|{\"Null\":{\"aws:ResourceTag/sre-agent:protect\":\"false\"}}",
      "Deny|logs:PutRetentionPolicy|*|{\"Null\":{\"aws:ResourceTag/sre-agent:protect\":\"false\"}}"
    ])
    error_message = "the module's policy differs from the one the product derives"
  }
}

run "one_group_off_removes_its_grants_and_its_deny" {
  command = plan

  variables {
    enable_address_release = false
  }

  assert {
    condition     = !contains(local.protected_writes, "ec2:ReleaseAddress")
    error_message = "the Deny must cover only writes the role is granted"
  }

  assert {
    condition     = !contains(local.any_reads, "ec2:DescribeAddresses")
    error_message = "the address reads must go with the address release"
  }
}

run "everything_off_leaves_no_statement_but_the_trust" {
  command = plan

  variables {
    enable_iam_deletions            = false
    enable_ebs_deletions            = false
    enable_address_release          = false
    enable_snapshot_image_deletions = false
    enable_log_retention            = false
  }

  assert {
    condition     = length(local.protected_writes) == 0 && length(local.any_reads) == 0
    error_message = "no group on means nothing granted and nothing to deny"
  }
}
