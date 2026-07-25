variable "external_id" {
  type        = string
  description = <<-EOT
    The ExternalId SRE Agent generated for your organization. Find it on the
    data-source settings page when configuring an AWS connection.

    Do not invent your own: the platform sends the value it generated, and a
    mismatch means every AssumeRole is denied. A shared or guessable value
    removes the confused-deputy protection this condition exists for.
  EOT

  validation {
    condition     = length(var.external_id) >= 16
    error_message = "external_id looks too short to be the generated value; copy it from the settings page."
  }
}

variable "trusted_principal_arn" {
  type        = string
  description = <<-EOT
    The SRE Agent platform principal allowed to assume this role.

    Shown alongside your ExternalId on the same settings page. It is the same
    for every customer and is useless on its own: without the matching
    ExternalId, AssumeRole is denied.
  EOT

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/", var.trusted_principal_arn))
    error_message = "trusted_principal_arn must be an IAM role or user ARN."
  }
}

variable "role_name" {
  type        = string
  description = "Name of the role SRE Agent assumes."
  default     = "sre-agent-readonly"
}

variable "policy_name" {
  type        = string
  description = "Name of the customer-managed policy attached to the role."
  default     = "sre-agent-readonly"
}

variable "max_session_duration" {
  type        = number
  description = <<-EOT
    Maximum session length in seconds. The product requests one hour by
    default and re-assumes as needed, so there is no reason to raise this.
  EOT
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

# --- Service toggles --------------------------------------------------------
# Each maps to a product feature. Turning one off is safe: the feature that
# needs it degrades to "no data" rather than erroring — which is worth knowing,
# because an empty page and a missing permission look identical in this
# product. If something reads as empty, check the policy before concluding
# there is nothing to report.

variable "enable_ec2" {
  type        = bool
  description = "EC2 read surface. Required for capacity planning and the FinOps waste detectors."
  default     = true
}

variable "enable_autoscaling" {
  type        = bool
  description = <<-EOT
    Auto Scaling groups. These decide how many instances a workload actually
    has, so capacity without them is a snapshot rather than a trend.
  EOT
  default     = true
}

variable "enable_ecs" {
  type        = bool
  description = "ECS clusters, services and tasks as capacity workloads."
  default     = true
}

variable "enable_eks" {
  type        = bool
  description = <<-EOT
    EKS clusters and node groups.

    This is the AWS-side view only (cluster, nodegroups, versions). Reading what
    runs *inside* the cluster needs the kubernetes-rbac module as well, because
    EKS authorises that separately through the cluster's own RBAC.
  EOT
  default     = true
}

variable "enable_lambda" {
  type        = bool
  description = "Lambda functions as capacity workloads."
  default     = true
}

variable "enable_load_balancing" {
  type        = bool
  description = <<-EOT
    Load balancers and target groups: where "the service is down" is usually
    first visible, and how a workload maps to the traffic reaching it.
  EOT
  default     = true
}

variable "enable_databases" {
  type        = bool
  description = <<-EOT
    RDS and ElastiCache metadata and configuration. No data-plane access exists
    in these actions — nothing here can read rows or keys.
  EOT
  default     = true
}

variable "enable_cloudwatch" {
  type        = bool
  description = "CloudWatch metrics and alarm state. Required for SLIs and utilization."
  default     = true
}

variable "enable_logs" {
  type        = bool
  description = "CloudWatch Logs search during investigations, including Insights queries."
  default     = true
}

variable "enable_cloudtrail" {
  type        = bool
  description = "CloudTrail, so an investigation can answer \"who changed what\"."
  default     = true
}

variable "enable_xray" {
  type        = bool
  description = "X-Ray trace summaries for latency investigations."
  default     = true
}

variable "enable_tagging" {
  type        = bool
  description = <<-EOT
    The resource tagging API, which resolves ownership across every service at
    once. Without it, deriving an owner means asking each service separately
    and missing anything neither side knows about.
  EOT
  default     = true
}

variable "enable_bedrock" {
  type        = bool
  description = <<-EOT
    Bedrock model access, only if you point SRE Agent's AI provider at Bedrock
    in your own account.

    Off by default, and the one block here that is not read-only: InvokeModel
    bills you directly. Most deployments use the platform's configured provider
    instead.
  EOT
  default     = false
}
