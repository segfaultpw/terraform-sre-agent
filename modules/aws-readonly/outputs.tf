output "role_arn" {
  description = "Paste this into the AWS data source in SRE Agent as the role ARN."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the created role."
  value       = aws_iam_role.this.name
}

output "policy_arn" {
  description = "ARN of the customer-managed policy attached to the role."
  value       = aws_iam_policy.this.arn
}

output "enabled_services" {
  description = "Services this role can read, for confirming what you granted."
  value       = sort(keys(local.enabled_statements))
}
