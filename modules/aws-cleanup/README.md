# aws-cleanup

The role behind SRE Agent's **AWS cleanup (deletions)** connector (`aws_cleanup`). It is the
only credential in the product that can delete anything, and **deleting this role is the
AWS-side kill switch for every deletion**: whatever Self-healing is set to do, nothing is deleted
once the role is gone.

Self-healing's deletions need more than the role: full autonomy for the organization, an
acknowledgement that names deletions, an organization admin's approval below full autonomy, and
the connector pinned on the area. This module only builds the role.

Separate from `aws-readonly`, `aws-ssm-remediation` and `aws-iam-hygiene` on purpose. No page or
scan (the capacity, FinOps and security pages, the inventory sweep, the scans) ever uses this
credential, only the checks a deletion makes about its own target do (they include reading recent
CloudTrail events with `cloudtrail:LookupEvents`), and a runbook step can never name the connector.

## Usage

```hcl
module "sre_agent_cleanup" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-cleanup?ref=v3.1.0"

  external_id           = "the-value-from-the-settings-page"
  trusted_principal_arn = "arn:aws:iam::111122223333:role/sre-agent-platform"
  aws_region            = "us-east-1"
}

output "role_arn" {
  value = module.sre_agent_cleanup.role_arn
}
```

Then create the connector with that `role_arn` and the same Region: Settings, Connectors, type
**AWS cleanup (deletions)**, authentication "assume role"; or the MCP `create_connector` tool with
`connector_type` `aws_cleanup`; or the Terraform provider's `sreagent_connector` with
`connector_type = "aws_cleanup"`. The FinOps and Security areas pin the connector (it never picks
one by itself). Volumes, snapshots, images, Elastic IPs, log groups and Recycle Bin rules are
regional: apply the module once per Region, with a connector for each. A finding in a Region with no
pinned connector is held as `region_mismatch`.

## The protect tag

The policy ends with a Deny of every destructive write the role is granted, on any resource
tagged `sre-agent:protect` (any value). SRE Agent checks the same tag itself and refuses before it
calls AWS; the Deny is the second lock, in your account. Allow statements carry no condition,
with two exceptions: `ec2:CreateTags` is allowed only while a snapshot or a volume is created
(`ec2:CreateAction` is `CreateSnapshot` or `CreateVolume`), so the role cannot add a tag to an
existing volume or snapshot, which would be a way around tag-based access control, and the KMS
actions that restoring an encrypted volume needs are allowed only when EC2 makes the call. A key in
another account must also allow this role in its own key policy. The Verify
button passes that context when it simulates, and never simulates a Deny.

**Tag your break-glass IAM users with `sre-agent:protect`.** The Deny covers `iam:DeleteAccessKey`
and `iam:DeleteLoginProfile` on a tagged user, so their keys and console passwords can never be
deleted by this role.

## The Recycle Bin rule

A snapshot or an image is deleted only while a Recycle Bin retention rule keeps it for at least 7
days. Create that rule yourself (Recycle Bin, Create retention rule, resource type EBS snapshots or
EBS-backed AMIs, in the Region of the connector); the module and SRE Agent never create one.

## What it grants

Each group is behind its own switch, all on by default. The product shows the same derivation under
Settings, Infrastructure, Show the policy ("Cleanup role (deletions)").

| Switch | Writes | Reads that prove it unused |
|---|---|---|
| `enable_iam_deletions` | `iam:DeleteAccessKey`, `iam:DeleteLoginProfile` on `user/*` | `iam:GetUser`, `iam:ListAccessKeys`, `iam:GetAccessKeyLastUsed`, `iam:GetLoginProfile`, `iam:ListMFADevices`, `iam:ListGroupsForUser`, the user and group policy listings, `iam:GetPolicy` and `iam:GetPolicyVersion` on `policy/*` (the customer-managed policies attached to the user or its groups, to tell whether the user can administer the account) |
| `enable_ebs_deletions` | `ec2:CreateSnapshot`, `ec2:CreateVolume`, `ec2:DeleteVolume`, and `ec2:CreateTags` only while a snapshot or volume is created on volumes and snapshots of the Region, and for a volume encrypted with a customer-managed key `kms:CreateGrant`, `kms:Decrypt`, `kms:DescribeKey`, `kms:GenerateDataKeyWithoutPlaintext`, `kms:ReEncryptFrom`, `kms:ReEncryptTo` on the keys of the account and Region, only when EC2 makes the call (`kms:ViaService`), and the grant only for an AWS service resource | `ec2:DescribeVolumes`, `ec2:DescribeSnapshots`, `cloudtrail:LookupEvents` |
| `enable_address_release` | `ec2:ReleaseAddress` on `elastic-ip/*` | `ec2:DescribeAddresses`, `ec2:DescribeAddressesAttribute` |
| `enable_snapshot_image_deletions` | `ec2:DeleteSnapshot`, `ec2:DeregisterImage`, `ec2:RestoreSnapshotFromRecycleBin`, `ec2:RestoreImageFromRecycleBin` | `ec2:DescribeSnapshots`, `ec2:DescribeSnapshotAttribute`, `ec2:DescribeImages`, `ec2:DescribeImageAttribute`, `ec2:DescribeInstances`, `ec2:DescribeLaunchTemplates`, `ec2:DescribeLaunchTemplateVersions`, `autoscaling:DescribeLaunchConfigurations`, `ec2:List*InRecycleBin`, `rbin:ListRules`, `rbin:GetRule` |
| `enable_log_retention` | `logs:PutRetentionPolicy`, `logs:DeleteRetentionPolicy` on the Region's log groups | `logs:DescribeLogGroups`, `logs:ListTagsForResource`, `cloudtrail:DescribeTrails` |
| `enable_verification` | `iam:SimulatePrincipalPolicy` (own role ARN only) | The Verify button checks this role against what the app derived, without a write. |

Describe and list calls authorize on no resource, so AWS requires `*` for them. Every write is
scoped to its resource type in the account and Region, never to one id, because the resource is
chosen at run time from a finding.

## Inputs

| Name | Type | Default | Required |
|---|---|---|:--:|
| `external_id` | `string` | | yes |
| `trusted_principal_arn` | `string` | | yes |
| `aws_region` | `string` | | yes |
| `enable_iam_deletions` | `bool` | `true` | no |
| `enable_ebs_deletions` | `bool` | `true` | no |
| `enable_address_release` | `bool` | `true` | no |
| `enable_snapshot_image_deletions` | `bool` | `true` | no |
| `enable_log_retention` | `bool` | `true` | no |
| `enable_verification` | `bool` | `true` | no |
| `protect_tag_key` | `string` | `"sre-agent:protect"` | no |
| `aws_partition` | `string` | `"aws"` | no |
| `role_name` / `policy_name` | `string` | `"sre-agent-cleanup"` | no |
| `max_session_duration` | `number` | `3600` | no |
| `permissions_boundary_arn` | `string` | `null` | no |
| `tags` | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `role_arn` | Paste into the AWS cleanup connector in SRE Agent |
| `role_name` | Name of the created role |
| `policy_arn` | ARN of the attached policy |
| `granted_reads` | The describe and list actions allowed on all resources |
| `protected_writes` | The destructive writes granted, each refused on a protect-tagged resource |
