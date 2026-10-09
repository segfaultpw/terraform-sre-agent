# The role behind the AWS IAM hygiene connector, so self-healing's Security area can
# deactivate an access key unused for 90 days. Separate from the read-only role on purpose:
# you can delete it without losing observability.

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

module "sre_agent_iam_hygiene" {
  # Relative path so this example is validated in CI. When you copy it, use the
  # published module and pin a version:
  #   source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-iam-hygiene?ref=v2.4.0"
  source = "../../modules/aws-iam-hygiene"

  external_id           = var.external_id
  trusted_principal_arn = var.trusted_principal_arn

  tags = {
    ManagedBy = "terraform"
    Purpose   = "sre-agent"
  }
}

output "role_arn" {
  description = "Paste into the AWS IAM hygiene connector in SRE Agent (type aws_iam)."
  value       = module.sre_agent_iam_hygiene.role_arn
}

output "granted" {
  description = "What you just allowed on the account's users."
  value       = module.sre_agent_iam_hygiene.granted_actions
}
