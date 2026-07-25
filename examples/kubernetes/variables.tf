variable "kubeconfig_path" {
  type        = string
  description = "Path to the kubeconfig used to create the RBAC objects."
  default     = "~/.kube/config"
}

variable "kube_context" {
  type        = string
  description = "Context within the kubeconfig."
  default     = null
}
