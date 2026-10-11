output "queue_url" {
  description = "The address the poller collects jobs from. It is the one shown in SRE Agent's Integrations page."
  value       = "${var.sre_agent_url}/api/verifier/queue"
}

output "api_key_scope" {
  description = "The one scope the API key in the secret must carry."
  value       = "verifier:poll"
}

output "poller_function_name" {
  description = "The Lambda function that polls. Its log group shows every poll and every refusal the platform gave, with the sentence that says what to upgrade."
  value       = aws_lambda_function.poller.function_name
}

output "poller_log_group" {
  description = "Log group of the poller."
  value       = aws_cloudwatch_log_group.poller.name
}

output "cluster_arn" {
  description = "The ECS cluster the verifier tasks run in."
  value       = aws_ecs_cluster.this.arn
}

output "task_log_group" {
  description = "Log group of the verifier tasks."
  value       = aws_cloudwatch_log_group.tasks.name
}

output "task_definition_families" {
  description = "The task definition family for each runtime."
  value       = { for runtime, definition in aws_ecs_task_definition.verifier : runtime => definition.family }
}

output "task_role_arn" {
  description = "The role the repository's code runs as. It has no permissions; do not attach any."
  value       = aws_iam_role.task.arn
}

output "private_subnet_ids" {
  description = "The subnets the tasks run in."
  value       = aws_subnet.private[*].id
}

output "security_group_id" {
  description = "The tasks' security group: no inbound, outbound HTTPS only."
  value       = aws_security_group.tasks.id
}

output "nat_public_ip" {
  description = "The address the tasks' outbound traffic comes from. Allow it wherever your package registry or source host restricts by address."
  value       = aws_eip.nat.public_ip
}
