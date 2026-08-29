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

variable "target_instance_tags" {
  type        = map(list(string))
  description = <<-EOT
    Which instances SRE Agent may run commands on, by tag. An instance must
    carry EVERY tag listed here.

    Strongly recommended over an account-wide grant, and the reason this module
    exists separately from aws-readonly:

        target_instance_tags = {
          "sre-agent-remediation" = ["true"]
        }

    Leaving this empty covers every SSM-managed instance in the account and is
    refused unless you also set i_understand_this_covers_every_instance.
  EOT
  default     = { "sre-agent-remediation" = ["true"] }
}

variable "i_understand_this_covers_every_instance" {
  type        = bool
  description = <<-EOT
    Set true only to deliberately grant command execution on EVERY SSM-managed
    instance in this account. Exists so that an unscoped grant is a decision
    somebody made, not an empty variable nobody noticed.
  EOT
  default     = false
}

variable "allowed_documents" {
  type        = list(string)
  description = <<-EOT
    SSM documents SRE Agent may run.

    The default is the one the product uses for shell steps. Note that
    AWS-RunShellScript executes arbitrary shell, so if you want a genuinely
    bounded grant, publish your own document with the specific remediations you
    are willing to automate and list that instead.
  EOT
  default     = ["AWS-RunShellScript"]

  validation {
    condition     = length(var.allowed_documents) > 0
    error_message = "At least one document must be allowed, otherwise this role can run nothing."
  }
}

variable "aws_region" {
  type        = string
  description = "Region the remediation targets live in."
}

variable "aws_partition" {
  type        = string
  description = "AWS partition (aws, aws-us-gov, aws-cn)."
  default     = "aws"
}

variable "role_name" {
  type        = string
  description = "Name of the remediation role."
  default     = "sre-agent-remediation"
}

variable "policy_name" {
  type        = string
  description = "Name of the customer-managed remediation policy."
  default     = "sre-agent-remediation"
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
