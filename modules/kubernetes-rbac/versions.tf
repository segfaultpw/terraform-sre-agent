terraform {
  required_version = ">= 1.5"

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      # 2.24 for wait_for_service_account_token on kubernetes_secret_v1.
      version = ">= 2.24"
    }
  }
}
