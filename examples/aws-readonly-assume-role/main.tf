# The recommended setup: SRE Agent assumes a role in your account. You never
# hand over an access key, and you can revoke access by deleting one role.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

module "sre_agent_readonly" {
  # Relative path so this example is validated in CI. When you copy it, use the
  # published module and pin a version:
  #   source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-readonly?ref=v2.0.1"
  source = "../../modules/aws-readonly"

  # Both values are shown on the AWS data-source form in SRE Agent:
  # Settings -> Data sources -> add/edit AWS -> auth type "assume role".
  # The ARN below is a sample; use the one the page shows you.
  external_id           = var.external_id
  trusted_principal_arn = var.trusted_principal_arn

  # Every group defaults on except Bedrock. Turn off anything you would rather
  # not have inspected; the feature that needs it then reports no data.
  enable_identity_read = true

  # Optional. Limit what SRE Agent can read from CloudWatch Logs to the groups
  # you list (unset: every log group in the account). See the module README.
  # log_group_arns = ["arn:aws:logs:us-east-1:111122223333:log-group:/aws/lambda/checkout"]

  # Optional. Read Amazon Managed Prometheus workspaces (off by default).
  # enable_prometheus         = true
  # prometheus_workspace_arns = ["arn:aws:aps:us-east-1:111122223333:workspace/ws-0123abcd"]

  tags = {
    ManagedBy = "terraform"
    Purpose   = "sre-agent"
  }
}

output "role_arn" {
  description = "Paste into the AWS data source in SRE Agent."
  value       = module.sre_agent_readonly.role_arn
}

output "granted" {
  description = "What you just granted read access to."
  value       = module.sre_agent_readonly.enabled_services
}
