# What this module must never loosen: runner_count tasks on the one workspace volume with the
# queue leasing each job to the instance that collects it (one task by default, replaced
# stop-first), no inbound and no load balancer, a task role that holds only the workspace, the
# memory prefix and what the operator attached, an execution role that reads only the named
# secrets, a container that starts as root and keeps the capabilities the runner needs to switch
# accounts, and an image that is not pinned by digest refused before anything is planned. Plans
# run against mocked providers, so no credentials, network or state are used.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }

  mock_resource "aws_ecs_cluster" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:123456789012:cluster/mock"
    }
  }

  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/mock:1"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:/ecs/mock"
    }
  }

  mock_resource "aws_ecs_service" {
    defaults = {
      id = "arn:aws:ecs:us-east-1:123456789012:service/mock/sre-agent-fix-runner"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn           = "arn:aws:lambda:us-east-1:123456789012:function:mock"
      function_name = "mock"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/mock"
    }
  }

  mock_resource "aws_ssm_parameter" {
    defaults = {
      arn = "arn:aws:ssm:us-east-1:123456789012:parameter/mock"
    }
  }

  mock_resource "aws_efs_file_system" {
    defaults = {
      id  = "fs-0123456789abcdef0"
      arn = "arn:aws:elasticfilesystem:us-east-1:123456789012:file-system/fs-0123456789abcdef0"
    }
  }

  mock_resource "aws_efs_access_point" {
    defaults = {
      id  = "fsap-0123456789abcdef0"
      arn = "arn:aws:elasticfilesystem:us-east-1:123456789012:access-point/fsap-0123456789abcdef0"
    }
  }
}

mock_provider "archive" {
  mock_data "archive_file" {
    defaults = {
      output_path         = ".build/scaler.zip"
      output_base64sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    }
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

variables {
  sre_agent_url           = "https://sre.example.com"
  sre_model               = "openrouter/deepseek/deepseek-v4-pro"
  image                   = "ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  api_key_secret_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-key-AbCdEf"
  github_token_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-github-GhIjKl"
  provider_key_secret_arns = {
    OPENROUTER_API_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr"
  }
  availability_zones = ["us-east-1a", "us-east-1b"]
}

# The state the plans below are read against: the default module, applied once.
run "the_default_count_is_one_task_replaced_stop_first_with_no_load_balancer" {
  command = apply

  assert {
    condition     = aws_ecs_service.this[0].desired_count == 1
    error_message = "runner_count defaults to one task, the 4.2.0 shape"
  }

  assert {
    condition     = aws_ecs_service.this[0].deployment_maximum_percent == 100 && aws_ecs_service.this[0].deployment_minimum_healthy_percent == 0
    error_message = "a deploy never runs more tasks than the count at once: it stops one before it starts its replacement"
  }

  assert {
    condition     = length(aws_ecs_service.this[0].load_balancer) == 0
    error_message = "no load balancer: nothing connects to the runner"
  }

  assert {
    condition     = aws_ecs_service.this[0].launch_type == "FARGATE"
    error_message = "Fargate"
  }

  assert {
    condition     = aws_ecs_service.this[0].network_configuration[0].assign_public_ip == false
    error_message = "the task gets no public address"
  }

  assert {
    condition     = aws_ecs_service.this[0].network_configuration[0].security_groups == toset([aws_security_group.tasks.id])
    error_message = "the service uses the module's security group"
  }

  assert {
    condition     = aws_ecs_service.this[0].deployment_circuit_breaker[0].enable == true && aws_ecs_service.this[0].deployment_circuit_breaker[0].rollback == true
    error_message = "a deployment that cannot start rolls back to the task that was running, instead of retrying with no one watching"
  }
}

run "one_task_with_workers_may_still_name_its_own_instance" {
  command = plan

  variables {
    concurrency       = 2
    extra_environment = { SRE_RUNNER_INSTANCE = "fixer" }
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_RUNNER_INSTANCE"] == "fixer"
    error_message = "the supervisor derives its workers' ids from the operator's base name; only a pool of tasks refuses a shared name"
  }
}

## The service
run "concurrency_zero_is_refused" {
  command = plan

  variables {
    concurrency = 0
  }

  expect_failures = [var.concurrency]
}

run "a_fractional_concurrency_is_refused" {
  command = plan

  variables {
    concurrency = 1.5
  }

  expect_failures = [var.concurrency]
}

run "a_task_too_small_for_its_workers_is_warned_about" {
  command = plan

  variables {
    concurrency = 5
  }

  expect_failures = [check.concurrency_fits_the_task]
}

run "a_task_that_fits_its_workers_raises_no_warning" {
  command = plan

  variables {
    concurrency = 2
  }
}

run "a_cpu_memory_pair_fargate_does_not_offer_is_still_refused_with_workers" {
  command = plan

  variables {
    concurrency = 4
    cpu         = 4096
    memory      = 9000
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "extra_environment_cannot_set_the_worker_count" {
  command = plan

  variables {
    extra_environment = { SRE_CONCURRENCY = "4" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_the_agent_role" {
  command = plan

  variables {
    extra_environment = { SRE_AGENT_AWS_ROLE_ARN = "arn:aws:iam::123456789012:role/agent-reads" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_the_split_workspace_with_workers" {
  command = plan

  variables {
    concurrency       = 2
    extra_environment = { SRE_WORKSPACE_PER_INSTANCE = "1" }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "extra_environment_cannot_set_the_memory_root_with_workers" {
  command = plan

  variables {
    concurrency       = 2
    extra_environment = { SRE_MEMORY_ROOT = "/workspace/memory" }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "hooks_variables_pass_through_extra_environment" {
  command = plan

  variables {
    extra_environment = {
      SRE_HOOKS_DIR            = "/opt/sre-hooks"
      SRE_HOOK_TIMEOUT_SECONDS = "120"
      SRE_TASK_PROTECTION      = "auto"
    }
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_HOOKS_DIR"] == "/opt/sre-hooks"
    error_message = "the hooks directory in the image reaches the runner"
  }
}

run "a_hooks_directory_under_the_volume_is_refused" {
  command = plan

  variables {
    extra_environment = { SRE_HOOKS_DIR = "/workspace/hooks" }
  }

  expect_failures = [var.extra_environment]
}

run "a_relative_hooks_directory_is_refused" {
  command = plan

  variables {
    extra_environment = { SRE_HOOKS_DIR = "hooks" }
  }

  expect_failures = [var.extra_environment]
}

run "a_hooks_directory_with_a_dot_dot_part_is_refused" {
  command = plan

  variables {
    extra_environment = { SRE_HOOKS_DIR = "/opt/../workspace/hooks" }
  }

  expect_failures = [var.extra_environment]
}

run "the_agent_role_is_assumed_by_the_task_role_and_nothing_more" {
  command = apply

  variables {
    agent_aws_access   = true
    agent_aws_role_arn = "arn:aws:iam::123456789012:role/agent-reads"
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_AGENT_AWS_ROLE_ARN"] == "arn:aws:iam::123456789012:role/agent-reads"
    error_message = "the role reaches the runner"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s if s.Sid == "AssumeTheAgentRole"
    ] == [{ Sid = "AssumeTheAgentRole", Effect = "Allow", Action = ["sts:AssumeRole"], Resource = "arn:aws:iam::123456789012:role/agent-reads" }]
    error_message = "one statement: assume exactly the named role"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      !contains(flatten([s.Resource]), "*")
    ])
    error_message = "no statement is on every resource"
  }
}

run "an_agent_role_without_agent_aws_access_is_refused" {
  command = plan

  variables {
    agent_aws_role_arn = "arn:aws:iam::123456789012:role/agent-reads"
  }

  expect_failures = [aws_iam_role_policy.task]
}

run "an_agent_role_that_is_not_a_role_arn_is_refused" {
  command = plan

  variables {
    agent_aws_access   = true
    agent_aws_role_arn = "arn:aws:iam::123456789012:user/someone"
  }

  expect_failures = [var.agent_aws_role_arn]
}

## Scaling

run "without_scaling_there_is_no_scaler_and_the_fleet_is_fixed" {
  command = apply

  assert {
    condition     = length(aws_ecs_service.this) == 1 && length(aws_ecs_service.scaled) == 0
    error_message = "the fixed fleet is the default"
  }

  assert {
    condition     = aws_ecs_service.this[0].name == "sre-agent-fix-runner"
    error_message = "the fixed fleet's service keeps its name"
  }

  assert {
    condition = (
      length(aws_lambda_function.scaler) == 0 && length(aws_iam_role.scaler) == 0 && length(aws_iam_role_policy.scaler) == 0
      && length(aws_cloudwatch_event_rule.scaler) == 0 && length(aws_cloudwatch_metric_alarm.scaler_errors) == 0
      && length(aws_cloudwatch_log_group.scaler) == 0 && length(aws_ssm_parameter.scaler_idle_since) == 0
      && length(data.archive_file.scaler) == 0
    )
    error_message = "no scaler resource exists unless scaling is set"
  }

  assert {
    condition     = output.scaler_function_name == null
    error_message = "no scaler to name"
  }

  assert {
    condition     = !contains([for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid], "ProtectTheTaskWhileItWorks")
    error_message = "the task role gains no task protection permission for a fixed fleet"
  }
}

# Runs of one file share state, so the creation is asserted first, as a plan: the mocked provider
# does not carry a value that ignore_changes covers through an apply, but the planned value is the
# one the real provider is asked to create the service with.
run "min_runners_is_the_service_s_starting_count" {
  command = plan

  variables {
    scaling = { min_runners = 1, max_runners = 2 }
  }

  assert {
    condition     = aws_ecs_service.scaled[0].desired_count == 1
    error_message = "the service starts at the minimum"
  }
}

run "scaling_replaces_the_fixed_service_with_one_the_scaler_owns" {
  command = apply

  variables {
    scaling = { max_runners = 3 }
  }

  assert {
    condition     = length(aws_ecs_service.this) == 0 && length(aws_ecs_service.scaled) == 1
    error_message = "one service, the scaled one"
  }

  assert {
    condition     = aws_ecs_service.scaled[0].name == "sre-agent-fix-runner-scaled"
    error_message = "a name of its own, so switching never has one name in two services"
  }

  assert {
    condition     = aws_ecs_service.scaled[0].desired_count == 0
    error_message = "min_runners defaults to 0: no task until there is work"
  }

  assert {
    condition     = aws_ecs_service.scaled[0].deployment_maximum_percent == 100 && aws_ecs_service.scaled[0].deployment_minimum_healthy_percent == 0 && length(aws_ecs_service.scaled[0].load_balancer) == 0
    error_message = "the same deployment bounds and no load balancer as the fixed fleet"
  }

  assert {
    condition     = aws_ecs_service.scaled[0].deployment_circuit_breaker[0].enable == true && aws_ecs_service.scaled[0].deployment_circuit_breaker[0].rollback == true
    error_message = "the same circuit breaker"
  }

  assert {
    condition     = aws_ecs_service.scaled[0].network_configuration[0].assign_public_ip == false
    error_message = "no public address"
  }

  assert {
    condition     = output.service_arn == aws_ecs_service.scaled[0].id
    error_message = "the output names whichever service exists"
  }
}

# The service now exists, so the count in state is the scaler's: a changed minimum must not be
# applied to it.
run "terraform_does_not_reset_the_count_the_scaler_set" {
  command = plan

  variables {
    scaling = { min_runners = 2, max_runners = 2 }
  }

  assert {
    condition     = aws_ecs_service.scaled[0].desired_count != 2
    error_message = "desired_count is ignored once the service exists: the scaler owns it, and an apply must not put it back"
  }
}

run "the_scaler_is_one_node_function_run_every_minute" {
  command = apply

  variables {
    scaling     = { min_runners = 0, max_runners = 4, idle_minutes = 15 }
    concurrency = 2
  }

  assert {
    condition     = aws_lambda_function.scaler[0].runtime == "nodejs24.x" && aws_lambda_function.scaler[0].handler == "index.handler"
    error_message = "Node 24 (the current supported runtime), index.handler"
  }

  assert {
    condition     = aws_lambda_function.scaler[0].function_name == "sre-agent-fix-runner-scaler"
    error_message = "named for the module"
  }

  assert {
    condition = aws_lambda_function.scaler[0].environment[0].variables == tomap({
      SRE_AGENT_URL      = "https://sre.example.com"
      API_KEY_SECRET_ARN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-key-AbCdEf"
      CLUSTER_ARN        = "arn:aws:ecs:us-east-1:123456789012:cluster/mock"
      SERVICE_NAME       = "sre-agent-fix-runner-scaled"
      IDLE_PARAMETER     = "/sre-agent-fix-runner/scaler/idle-since"
      MIN_RUNNERS        = "0"
      MAX_RUNNERS        = "4"
      CONCURRENCY        = "2"
      IDLE_MINUTES       = "15"
    })
    error_message = "the function is told the platform, the key's secret (an ARN, never the key), the service and the bounds"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.scaler[0].schedule_expression == "rate(1 minute)"
    error_message = "once a minute"
  }

  assert {
    condition     = aws_cloudwatch_event_target.scaler[0].rule == aws_cloudwatch_event_rule.scaler[0].name && aws_lambda_permission.scaler[0].principal == "events.amazonaws.com"
    error_message = "EventBridge may invoke it, and only the rule"
  }

  assert {
    condition     = aws_lambda_permission.scaler[0].source_arn == aws_cloudwatch_event_rule.scaler[0].arn
    error_message = "the permission is on the module's own rule"
  }

  assert {
    condition     = aws_lambda_function_event_invoke_config.scaler[0].maximum_retry_attempts == 0
    error_message = "the next minute is the retry"
  }

  assert {
    condition     = aws_cloudwatch_log_group.scaler[0].name == "/aws/lambda/sre-agent-fix-runner-scaler" && aws_cloudwatch_log_group.scaler[0].retention_in_days == 30
    error_message = "logs go to a group of their own with the module's retention"
  }

  assert {
    condition     = output.scaler_function_name == "sre-agent-fix-runner-scaler"
    error_message = "the output names the function"
  }
}

run "the_idle_clock_is_a_parameter_terraform_never_resets" {
  command = apply

  variables {
    scaling = { max_runners = 2 }
  }

  assert {
    condition     = aws_ssm_parameter.scaler_idle_since[0].name == "/sre-agent-fix-runner/scaler/idle-since" && aws_ssm_parameter.scaler_idle_since[0].type == "String" && aws_ssm_parameter.scaler_idle_since[0].value == "0"
    error_message = "starts at 0, not idle"
  }
}

run "the_scaler_role_can_scale_this_service_read_one_secret_and_nothing_else" {
  command = apply

  variables {
    scaling = { max_runners = 2 }
  }

  assert {
    condition = toset([
      for s in jsondecode(aws_iam_role_policy.scaler[0].policy).Statement : s.Sid
    ]) == toset(["WriteItsOwnLogs", "ReadTheApiKey", "ScaleThisServiceOnly", "KeepTheIdleClock"])
    error_message = "logs, the key, the service, the idle clock"
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.scaler[0].policy).Statement : s.Action
      ])) == toset([
      "logs:CreateLogStream", "logs:PutLogEvents", "secretsmanager:GetSecretValue",
      "ecs:DescribeServices", "ecs:UpdateService", "ssm:GetParameter", "ssm:PutParameter",
    ])
    error_message = "the scaler's whole action list"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.scaler[0].policy).Statement :
      !contains(flatten([s.Resource]), "*")
    ])
    error_message = "no statement is on every resource"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.scaler[0].policy).Statement : s.Resource if s.Sid == "ScaleThisServiceOnly"
    ][0] == aws_ecs_service.scaled[0].id
    error_message = "update and describe on the one service"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.scaler[0].policy).Statement : s.Resource if s.Sid == "ReadTheApiKey"
    ][0] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-key-AbCdEf"
    error_message = "the one key secret"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.scaler[0].policy).Statement : s.Resource if s.Sid == "KeepTheIdleClock"
    ][0] == aws_ssm_parameter.scaler_idle_since[0].arn
    error_message = "the one parameter"
  }

  assert {
    condition     = jsondecode(aws_iam_role.scaler[0].assume_role_policy).Statement[0].Principal.Service == "lambda.amazonaws.com"
    error_message = "Lambda assumes it"
  }

  assert {
    condition     = length(aws_iam_role.scaler[0].managed_policy_arns) == 0 && length(aws_iam_role.scaler[0].inline_policy) == 0
    error_message = "nothing is embedded or attached beside the one policy"
  }
}

run "a_customer_managed_secrets_key_is_usable_by_the_scaler_through_secrets_manager_only" {
  command = apply

  variables {
    scaling             = { max_runners = 2 }
    secrets_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.scaler[0].policy).Statement : s.Condition if s.Sid == "DecryptTheApiKey"
      ][0] == {
      StringEquals = {
        "kms:ViaService"                  = "secretsmanager.us-east-1.amazonaws.com"
        "kms:EncryptionContext:SecretARN" = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-key-AbCdEf"
      }
    }
    error_message = "decrypt only through Secrets Manager and only for the key's secret"
  }
}

run "without_a_secrets_key_the_scaler_holds_no_kms_permission" {
  command = apply

  variables {
    scaling = { max_runners = 2 }
  }

  assert {
    condition     = !anytrue([for s in jsondecode(aws_iam_role_policy.scaler[0].policy).Statement : anytrue([for a in flatten([s.Action]) : startswith(a, "kms:")])])
    error_message = "no kms action"
  }
}

run "a_scaler_that_fails_raises_an_alarm_that_notifies_whoever_is_named" {
  command = apply

  variables {
    scaling       = { max_runners = 2 }
    alarm_actions = ["arn:aws:sns:us-east-1:123456789012:oncall"]
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.scaler_errors[0].metric_name == "Errors" && aws_cloudwatch_metric_alarm.scaler_errors[0].namespace == "AWS/Lambda"
    error_message = "on the function's errors"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.scaler_errors[0].dimensions == tomap({ FunctionName = "sre-agent-fix-runner-scaler" })
    error_message = "for this function"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.scaler_errors[0].evaluation_periods == 3 && aws_cloudwatch_metric_alarm.scaler_errors[0].datapoints_to_alarm == 3 && aws_cloudwatch_metric_alarm.scaler_errors[0].period == 300
    error_message = "fifteen minutes running, so a blip does not page"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.scaler_errors[0].alarm_actions == toset(["arn:aws:sns:us-east-1:123456789012:oncall"])
    error_message = "the named topic"
  }
}

run "the_alarm_exists_even_with_no_action_named" {
  command = apply

  variables {
    scaling = { max_runners = 2 }
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.scaler_errors) == 1 && length(aws_cloudwatch_metric_alarm.scaler_errors[0].alarm_actions) == 0
    error_message = "the module creates the alarm; notifying is the operator's choice"
  }
}

run "a_scaled_task_may_protect_itself_and_only_tasks_of_its_cluster" {
  command = apply

  variables {
    scaling = { max_runners = 2 }
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Action if s.Sid == "ProtectTheTaskWhileItWorks"
    ][0] == ["ecs:GetTaskProtection", "ecs:UpdateTaskProtection"]
    error_message = "read and set its own protection"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Resource if s.Sid == "ProtectTheTaskWhileItWorks"
    ][0] == "arn:aws:ecs:us-east-1:123456789012:task/mock/*"
    error_message = "the tasks of the one cluster"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      !contains(flatten([s.Resource]), "*")
    ])
    error_message = "no statement is on every resource"
  }
}

run "scaling_above_one_task_uses_the_pool_layout" {
  command = apply

  variables {
    scaling = { max_runners = 3 }
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_WORKSPACE_PER_INSTANCE"] == "1" && { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_MEMORY_ROOT"] == "/workspace/memory"
    error_message = "tasks that come and go still share one volume under instances/<id>"
  }
}

run "scaling_to_at_most_one_task_keeps_the_single_task_layout" {
  command = apply

  variables {
    scaling = { max_runners = 1 }
  }

  assert {
    condition     = !contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name], "SRE_WORKSPACE_PER_INSTANCE")
    error_message = "one task at most: no pool layout"
  }
}

run "a_scaled_pool_refuses_one_shared_identity" {
  command = plan

  variables {
    scaling           = { max_runners = 2 }
    extra_environment = { SRE_RUNNER_INSTANCE = "shared" }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_scaled_pool_refuses_the_image_that_cannot_lease" {
  command = plan

  variables {
    scaling = { max_runners = 2 }
    image   = "ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:ef95a56a8ae2763e7c9b1a98e261443a4489ca78ba449d47331f3d7a163b1b52"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_fixed_count_with_scaling_is_refused" {
  command = plan

  variables {
    scaling      = { max_runners = 2 }
    runner_count = 2
  }

  expect_failures = [aws_ecs_service.scaled]
}

run "a_maximum_below_the_minimum_is_refused" {
  command = plan

  variables {
    scaling = { min_runners = 3, max_runners = 2 }
  }

  expect_failures = [var.scaling]
}

run "a_maximum_of_zero_is_refused" {
  command = plan

  variables {
    scaling = { max_runners = 0 }
  }

  expect_failures = [var.scaling]
}

run "a_fractional_runner_bound_is_refused" {
  command = plan

  variables {
    scaling = { min_runners = 0.5, max_runners = 2 }
  }

  expect_failures = [var.scaling]
}

run "a_negative_minimum_is_refused" {
  command = plan

  variables {
    scaling = { min_runners = -1, max_runners = 2 }
  }

  expect_failures = [var.scaling]
}

run "idle_minutes_outside_one_to_1440_is_refused" {
  command = plan

  variables {
    scaling = { max_runners = 2, idle_minutes = 0 }
  }

  expect_failures = [var.scaling]
}

run "idle_minutes_above_a_day_is_refused" {
  command = plan

  variables {
    scaling = { max_runners = 2, idle_minutes = 1441 }
  }

  expect_failures = [var.scaling]
}
