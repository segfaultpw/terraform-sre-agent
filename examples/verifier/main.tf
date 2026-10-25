# Where SRE Agent's sandbox verification runs, in your own account: a poller that asks SRE Agent
# for work, Fargate task definitions for the published verifier images, a network with outbound
# HTTPS only, and a task role with no permissions.
#
# Before applying, create the API key and the secret that holds it, once, outside Terraform so the
# key never enters state:
#
#   1. SRE Agent, Settings, API Keys: create a key with the single scope verifier:poll.
#   2. Paste the key into a file only you can read (umask 077; cat > verifier-key.txt), create the
#      secret with --secret-string file://verifier-key.txt so the key is never on a command line,
#      then delete the file. The value is the plain key, not key/value JSON.
#
# Then pass the secret's full ARN (with its six-character suffix) as api_key_secret_arn, and the
# image digests from the "Published images" table in modules/verifier/README.md as images (the
# Integrations card in SRE Agent shows what it accepts now), and apply.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = var.region
}

module "sre_agent_verifier" {
  # Relative path so this example is validated in CI. When you copy it, use the
  # published module and pin a version:
  #   source = "github.com/segfaultpw/terraform-sre-agent//modules/verifier?ref=v4.1.0"
  source = "../../modules/verifier"

  sre_agent_url      = var.sre_agent_url
  api_key_secret_arn = var.api_key_secret_arn

  # Only the runtimes your repositories use, each pinned by digest.
  images = var.images

  tags = {
    ManagedBy = "terraform"
    Purpose   = "sre-agent"
  }
}

output "queue_url" {
  description = "The address the poller collects jobs from (shown in SRE Agent, Integrations)."
  value       = module.sre_agent_verifier.queue_url
}

output "poller_log_group" {
  description = "Read this to see each poll and any refusal, with what to upgrade."
  value       = module.sre_agent_verifier.poller_log_group
}

output "nat_public_ip" {
  description = "Where the tasks' outbound traffic comes from."
  value       = module.sre_agent_verifier.nat_public_ip
}
