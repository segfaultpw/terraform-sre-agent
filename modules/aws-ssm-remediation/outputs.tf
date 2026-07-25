output "role_arn" {
  description = "Paste this into SRE Agent as the remediation connector's role ARN."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the created remediation role."
  value       = aws_iam_role.this.name
}

output "policy_arn" {
  description = "ARN of the customer-managed remediation policy."
  value       = aws_iam_policy.this.arn
}

output "scoped_to_tags" {
  description = "The tags an instance must carry to be reachable. Empty means every managed instance."
  value       = var.target_instance_tags
}
