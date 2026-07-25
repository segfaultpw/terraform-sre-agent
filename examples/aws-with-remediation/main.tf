# Read-only access plus opt-in remediation.
#
# The remediation role is separate on purpose: you can delete it without losing
# observability, and it is scoped to instances you explicitly tag.

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

  external_id           = var.external_id
  trusted_principal_arn = var.trusted_principal_arn
}

module "sre_agent_remediation" {
  # Relative path so this example is validated in CI. When you copy it, use the
  # published module and pin a version:
  #   source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-ssm-remediation?ref=v2.0.1"
  source = "../../modules/aws-ssm-remediation"

  external_id           = var.external_id
  trusted_principal_arn = var.trusted_principal_arn
  aws_region            = var.region

  # Only instances carrying this tag can be touched. Tag them deliberately:
  # this is command execution, not monitoring.
  target_instance_tags = {
    "sre-agent-remediation" = ["true"]
  }

  # Replace with your own SSM document to bound what can be run.
  # AWS-RunShellScript is arbitrary shell.
  allowed_documents = ["AWS-RunShellScript"]
}

output "readonly_role_arn" {
  value = module.sre_agent_readonly.role_arn
}

output "remediation_role_arn" {
  value = module.sre_agent_remediation.role_arn
}
