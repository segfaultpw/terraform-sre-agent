# The role behind the AWS cleanup connector, so self-healing can delete what scans found
# unused once you have turned deletions on. Separate from every other role on purpose:
# deleting it stops every deletion SRE Agent could make.

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

module "sre_agent_cleanup" {
  # Relative path so this example is validated in CI. When you copy it, use the
  # published module and pin a version:
  #   source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-cleanup?ref=v3.1.0"
  source = "../../modules/aws-cleanup"

  external_id           = var.external_id
  trusted_principal_arn = var.trusted_principal_arn
  aws_region            = var.region

  # Turn off any group of deletions you do not want the role to be able to make.
  enable_log_retention = false

  tags = {
    ManagedBy = "terraform"
    Purpose   = "sre-agent"
  }
}

output "role_arn" {
  description = "Paste into the AWS cleanup connector in SRE Agent (type aws_cleanup)."
  value       = module.sre_agent_cleanup.role_arn
}

output "protected_writes" {
  description = "The destructive writes you just allowed, each refused on a resource tagged sre-agent:protect."
  value       = module.sre_agent_cleanup.protected_writes
}
