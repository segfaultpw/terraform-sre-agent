variable "external_id" {
  type        = string
  description = "The ExternalId SRE Agent generated for your organization. See the aws-readonly module."

  validation {
    condition     = length(var.external_id) >= 16
    error_message = "external_id looks too short to be the generated value; copy it from the settings page."
  }
}

variable "trusted_principal_arn" {
  type        = string
  description = "The SRE Agent platform principal allowed to assume this role."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/", var.trusted_principal_arn))
    error_message = "trusted_principal_arn must be an IAM role or user ARN."
  }
}

variable "aws_region" {
  type        = string
  description = <<-EOT
    The Region the AWS cleanup connector is configured with. Volumes, snapshots, images,
    Elastic IPs, log groups and Recycle Bin rules are regional, so every write is scoped to
    this Region. Apply the module once per Region you want cleaned up, with a connector for
    each. IAM is global and is not affected.
  EOT

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a Region name such as us-east-1."
  }
}

variable "enable_iam_deletions" {
  type        = bool
  description = <<-EOT
    iam:DeleteAccessKey and iam:DeleteLoginProfile, with the reads that prove a key or a
    password unused, on the account's users. The Security area deletes an access key it
    deactivated 30 days earlier, and the console password of a user who never added MFA.
    Neither can be restored.
  EOT
  default     = true
}

variable "enable_ebs_deletions" {
  type        = bool
  description = <<-EOT
    The FinOps area's unattached-volume deletion: ec2:CreateSnapshot and ec2:CreateTags for
    the backup, ec2:DeleteVolume, and ec2:CreateVolume to recreate the volume from the
    snapshot.
  EOT
  default     = true
}

variable "enable_address_release" {
  type        = bool
  description = "ec2:ReleaseAddress, for an Elastic IP unassociated for 30 days. It cannot be restored."
  default     = true
}

variable "enable_snapshot_image_deletions" {
  type        = bool
  description = <<-EOT
    ec2:DeleteSnapshot and ec2:DeregisterImage, with the restores from the Recycle Bin and
    the reads of your Recycle Bin rules (rbin:ListRules, rbin:GetRule). SRE Agent deletes a
    snapshot or an image only while a rule keeps it for at least 7 days; create that rule
    yourself, it is never created for you.
  EOT
  default     = true
}

variable "enable_log_retention" {
  type        = bool
  description = <<-EOT
    logs:PutRetentionPolicy and logs:DeleteRetentionPolicy, to set the retention you choose
    on a log group that never expires and to take it off again. AWS removes the events older
    than the retention within about 72 hours and they cannot be brought back.
  EOT
  default     = true
}

variable "protect_tag_key" {
  type        = string
  description = <<-EOT
    The tag whose presence (any value) makes AWS refuse every destructive write on a
    resource. SRE Agent checks the same tag itself. Leave the default unless you changed the
    tag in the product.
  EOT
  default     = "sre-agent:protect"
}

variable "enable_verification" {
  type        = bool
  description = <<-EOT
    iam:SimulatePrincipalPolicy, scoped to this role's own ARN, so the product's Verify
    button can ask IAM "does this role allow what the app derived?" and answer with
    evidence instead of "unverified". Read-only, and it can simulate nothing but the role it
    rides on.
  EOT
  default     = true
}

variable "aws_partition" {
  type        = string
  description = "AWS partition (aws, aws-us-gov, aws-cn)."
  default     = "aws"
}

variable "role_name" {
  type        = string
  description = "Name of the cleanup role."
  default     = "sre-agent-cleanup"
}

variable "policy_name" {
  type        = string
  description = "Name of the customer-managed cleanup policy."
  default     = "sre-agent-cleanup"
}

variable "max_session_duration" {
  type        = number
  description = "Maximum session length in seconds."
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 900 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 900 and 43200 seconds."
  }
}

variable "permissions_boundary_arn" {
  type        = string
  description = "Optional permissions boundary to attach to the role."
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the role and policy."
  default     = {}
}
