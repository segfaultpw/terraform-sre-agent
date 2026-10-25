# SRE Agent's self-hosted fix runner on ECS Fargate, in your own account: one task that polls SRE
# Agent for fix requests, a workspace volume that keeps its clones and notes, and a bucket you own
# that mirrors the notes.
#
# Before applying, create the three secrets once, outside Terraform so no value enters state. Paste
# each value into a file only you can read (umask 077; cat > value.txt), create the secret with
# --secret-string file://value.txt so the value is never on a command line, then delete the file.
# Each value is the plain string, not key/value JSON:
#
#   1. SRE Agent, Settings, API Keys: a key with the single scope fix_runner:poll.
#   2. A GitHub token that may push a branch and open a pull request in the repositories to fix
#      (contents and pull requests, write).
#   3. Your model provider's API key.
#
# Then register the runner in SRE Agent (Integrations, Fix runner), pass the three secrets' full ARNs
# (with their six-character suffixes) and an image digest from the sre-agent-opencode release you
# want, and apply.

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

module "sre_agent_fix_runner" {
  # Relative path so this example is validated in CI. When you copy it, use the
  # published module and pin a version:
  #   source = "github.com/segfaultpw/terraform-sre-agent//modules/fix-runner?ref=v4.2.0"
  source = "../../modules/fix-runner"

  sre_agent_url = var.sre_agent_url
  sre_model     = var.sre_model
  image         = var.image

  api_key_secret_arn      = var.api_key_secret_arn
  github_token_secret_arn = var.github_token_secret_arn
  provider_key_secret_arns = {
    (var.provider_key_variable) = var.provider_key_secret_arn
  }

  tags = {
    ManagedBy = "terraform"
    Purpose   = "sre-agent"
  }
}

output "service_arn" {
  description = "The ECS service that runs the fix runner."
  value       = module.sre_agent_fix_runner.service_arn
}

output "log_group" {
  description = "Read this to see each poll and every request the runner handled."
  value       = module.sre_agent_fix_runner.log_group
}

output "memory_bucket_name" {
  description = "Where the runner mirrors its notes and scripts."
  value       = module.sre_agent_fix_runner.memory_bucket_name
}

output "nat_public_ip" {
  description = "Where the runner's outbound traffic comes from."
  value       = module.sre_agent_fix_runner.nat_public_ip
}
