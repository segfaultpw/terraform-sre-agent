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

variable "enable_key_changes" {
  type        = bool
  description = <<-EOT
    iam:UpdateAccessKey, which sets an access key Active or Inactive. It is what
    the Security area uses to deactivate an unused key and to put it back.

    Turn it off for a role that can only read who holds a key: the connector's
    deactivate and reactivate actions then fail with an AWS access denied and
    nothing is changed.
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
  description = "Name of the IAM hygiene role."
  default     = "sre-agent-iam-hygiene"
}

variable "policy_name" {
  type        = string
  description = "Name of the customer-managed IAM hygiene policy."
  default     = "sre-agent-iam-hygiene"
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

variable "enable_verification" {
  type        = bool
  description = <<-EOT
    iam:SimulatePrincipalPolicy, scoped to this role's own ARN, so the
    product's Verify button can ask IAM "does this role allow what the app
    derived?" and answer with evidence instead of "unverified".

    Read-only, and it can simulate nothing but the role it rides on. Refuse it
    and everything else keeps working; the app just can no longer tell you
    whether it does.
  EOT
  default     = true
}
