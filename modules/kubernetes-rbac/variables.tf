variable "namespace" {
  type        = string
  description = "Namespace for the ServiceAccount. The role itself is cluster-scoped."
  default     = "kube-system"
}

variable "service_account_name" {
  type        = string
  description = "Name of the ServiceAccount SRE Agent authenticates as."
  default     = "sre-agent"
}

variable "cluster_role_name" {
  type        = string
  description = "Name of the read-only ClusterRole."
  default     = "sre-agent-readonly"
}

variable "cluster_role_binding_name" {
  type        = string
  description = "Name of the ClusterRoleBinding."
  default     = "sre-agent-readonly"
}

variable "enable_metrics" {
  type        = bool
  description = <<-EOT
    Grant metrics.k8s.io (pods, nodes). Requires metrics-server in the cluster.

    Without it the capacity page shows requests but no usage, which reads as
    "nothing is over-provisioned" rather than as missing data, so leave this
    on unless you know metrics-server is absent.
  EOT
  default     = true
}

variable "enable_events" {
  type        = bool
  description = <<-EOT
    Grant read access to events. These are the most useful signal during an
    investigation (OOMKills, failed scheduling, image pull errors), but event
    messages can carry application detail, so it is separately controllable.
  EOT
  default     = true
}

variable "create_token" {
  type        = bool
  description = <<-EOT
    Create a long-lived ServiceAccount token Secret.

    Needed on Kubernetes 1.24+, which no longer mints one automatically. It is
    long-lived because SRE Agent connects from outside the cluster and cannot
    refresh a projected token. If you have your own short-lived token
    rotation, set this false and supply the token yourself.
  EOT
  default     = true
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to every created object."
  default     = { "app.kubernetes.io/name" = "sre-agent" }
}
