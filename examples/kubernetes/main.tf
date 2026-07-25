# Read-only cluster access for SRE Agent.

terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.24"
    }
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

module "sre_agent_rbac" {
  # Relative path so this example is validated in CI. When you copy it, use the
  # published module and pin a version:
  #   source = "github.com/segfaultpw/terraform-sre-agent//modules/kubernetes-rbac?ref=v1.0.0"
  source = "../../modules/kubernetes-rbac"

  namespace = "kube-system"

  # Leave on unless metrics-server is not installed; without it the capacity
  # page shows requests but no usage.
  enable_metrics = true
}

# Read with: terraform output -raw token
output "token" {
  description = "Bearer token for the Kubernetes connector."
  value       = module.sre_agent_rbac.token
  sensitive   = true
}
