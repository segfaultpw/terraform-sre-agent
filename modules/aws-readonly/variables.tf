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

# --- Service groups ---------------------------------------------------------
# Grouped rather than one toggle per service: at this breadth a per-service list
# is unreviewable, and these groups match how people reason about what they are
# willing to expose.
#
# Turning one off is safe: the feature that needs it degrades to "no data"
# rather than erroring. That is worth knowing, because an empty page and a
# missing permission look identical in this product. If something reads as
# empty, check the policy before concluding there is nothing to report.

variable "enable_compute" {
  type        = bool
  description = <<-EOT
    EC2 (instances, EBS volumes, EIPs, snapshots, AMIs, security groups,
    subnets, VPCs), Auto Scaling, ECS, EKS, Lambda, Elastic Beanstalk, Batch.

    Capacity planning and most FinOps waste detectors are built on this group.
  EOT
  default     = true
}

variable "enable_storage" {
  type        = bool
  description = <<-EOT
    S3 bucket configuration, EFS, FSx and Backup.

    Configuration only: lifecycle rules, storage class, tags, versioning: the
    things that turn "you have 400 buckets" into "this one has no lifecycle
    rule". Bucket *listing* is included because inventory needs it;
    `s3:GetObject` is not, so object contents stay unreadable.
  EOT
  default     = true
}

variable "enable_databases" {
  type        = bool
  description = <<-EOT
    RDS, DynamoDB, ElastiCache, Redshift and MemoryDB metadata and sizing.

    No data-plane reads: `DescribeTable` tells you a table's capacity mode,
    `GetItem` would tell you what is in it and is absent.
  EOT
  default     = true
}

variable "enable_streaming" {
  type        = bool
  description = <<-EOT
    Kinesis, Firehose, SQS, SNS, MSK and EventBridge.

    Stream and queue shape, not payloads: `DescribeStream` but not
    `GetRecords`, `GetQueueAttributes` but not `ReceiveMessage`.
  EOT
  default     = true
}

variable "enable_networking" {
  type        = bool
  description = <<-EOT
    Load balancers, Route 53, CloudFront, API Gateway, Direct Connect, Global
    Accelerator and ACM: how traffic reaches a workload, and where "the service
    is down" is usually first visible.

    ACM certificates are listed and described so their expiry can be watched
    before it takes an endpoint down. The private key is never reachable:
    `acm:ExportCertificate` is absent.
  EOT
  default     = true
}

variable "enable_observability" {
  type        = bool
  description = <<-EOT
    CloudWatch metrics and alarms, CloudWatch Logs (including Insights
    queries), X-Ray traces, CloudTrail and AWS Health.

    Without CloudWatch nothing is ever "idle" or "oversized", because there is
    no utilization to judge it by.
  EOT
  default     = true
}

variable "enable_cost" {
  type        = bool
  description = <<-EOT
    Cost Explorer, Budgets, Pricing, Savings Plans, Compute Optimizer and Cost
    Optimization Hub.

    This is the difference between estimating savings from a hard-coded price
    list and reporting what the account is actually billed. Compute Optimizer
    in particular is AWS's own rightsizing analysis, which is stronger evidence
    than inferring from CPU alone.

    Note that Cost Explorer and Pricing API calls are themselves billed per
    request.
  EOT
  default     = true
}

variable "enable_governance" {
  type        = bool
  description = <<-EOT
    Resource tagging, Resource Groups, AWS Config, Organizations and Service
    Quotas.

    The tagging API resolves ownership across every service at once, instead of
    asking each one separately and missing whatever neither side knows about.
  EOT
  default     = true
}

variable "enable_identity_read" {
  type        = bool
  description = <<-EOT
    IAM read: turns a CloudTrail entry from "some principal" into "this role",
    which is the difference between a timeline and an explanation.

    Exposes your principal inventory (names, attached policies, last-used),
    though no credentials. Its own toggle for anyone who would rather it did
    not.
  EOT
  default     = true
}

variable "enable_inventory" {
  type        = bool
  description = <<-EOT
    SSM inventory, Secrets Manager metadata, ECR and Step Functions: existence
    and configuration of things the other groups do not name.

    Secrets are listed and described, never read: `GetSecretValue` is absent,
    as is `ssm:GetParameter`.
  EOT
  default     = true
}

variable "enable_bedrock" {
  type        = bool
  description = <<-EOT
    Bedrock model access, only if you point SRE Agent's AI provider at Bedrock
    in your own account.

    Off by default, and the one group here that is not read-only: `InvokeModel`
    bills you directly. Most deployments use the platform's configured provider
    instead.
  EOT
  default     = false
}
