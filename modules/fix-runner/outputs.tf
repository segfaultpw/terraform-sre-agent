output "service_arn" {
  description = "The ECS service that runs the fix runner."
  value       = aws_ecs_service.this.id
}

output "cluster_arn" {
  description = "The ECS cluster the service runs in."
  value       = local.cluster_arn
}

output "memory_bucket_name" {
  description = "The bucket the runner mirrors its memory to, under memory_prefix."
  value       = local.bucket_name
}

output "memory_prefix" {
  description = "The prefix of the memory mirror in that bucket."
  value       = var.memory_prefix
}

output "file_system_id" {
  description = "The workspace volume, mounted at /workspace."
  value       = aws_efs_file_system.this.id
}

output "access_point_arn" {
  description = "The access point the task mounts the volume through."
  value       = aws_efs_access_point.this.arn
}

output "log_group" {
  description = "The runner's log group: every poll, request and refusal the runner logs."
  value       = aws_cloudwatch_log_group.this.name
}

output "api_key_scope" {
  description = "The one scope the API key in the secret must carry."
  value       = "fix_runner:poll"
}

output "task_role_arn" {
  description = "The role the runner holds (and the agent too with agent_aws_access): the workspace, the memory prefix and extra_policy_arns."
  value       = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "The task role's name, to attach more policies outside this module."
  value       = aws_iam_role.task.name
}

output "security_group_id" {
  description = "The task's security group: no inbound, outbound HTTPS, the volume and extra_egress_ports."
  value       = aws_security_group.tasks.id
}

output "private_subnet_ids" {
  description = "The subnets the task runs in."
  value       = local.subnet_ids
}

output "nat_public_ip" {
  description = "The address the runner's outbound traffic comes from, when this module built the network (null with an existing VPC). Allow it wherever your source host or package registry restricts by address."
  value       = local.create_network ? aws_eip.nat[0].public_ip : null
}
