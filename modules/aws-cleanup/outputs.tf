output "role_arn" {
  description = "Paste this into SRE Agent as the AWS cleanup connector's role ARN."
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

output "granted_reads" {
  description = "The describe and list actions allowed on all resources, for confirming what you granted."
  value       = local.any_reads
}

output "protected_writes" {
  description = "The destructive writes the role is granted, each refused on a resource tagged with the protect tag."
  value       = local.protected_writes
}
