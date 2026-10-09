output "role_arn" {
  description = "Paste this into SRE Agent as the AWS IAM hygiene connector's role ARN."
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

output "granted_actions" {
  description = "The IAM actions the role is allowed on the account's users, for confirming what you granted."
  value       = sort(concat(local.read_actions, local.write_actions))
}
