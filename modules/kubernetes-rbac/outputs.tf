output "service_account_name" {
  description = "Name of the created ServiceAccount."
  value       = kubernetes_service_account_v1.this.metadata[0].name
}

output "namespace" {
  description = "Namespace the ServiceAccount lives in."
  value       = kubernetes_service_account_v1.this.metadata[0].namespace
}

output "cluster_role_name" {
  description = "Name of the created ClusterRole."
  value       = kubernetes_cluster_role_v1.this.metadata[0].name
}

output "token" {
  description = <<-EOT
    Bearer token for the Kubernetes connector in SRE Agent.

    Sensitive: it grants read access to the whole cluster. Read it with
    `terraform output -raw token` and paste it into the connector; do not
    commit it or echo it into CI logs.
  EOT
  value       = var.create_token ? kubernetes_secret_v1.token[0].data["token"] : null
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "The cluster CA certificate, for connectors that verify TLS."
  value       = var.create_token ? kubernetes_secret_v1.token[0].data["ca.crt"] : null
  sensitive   = true
}
