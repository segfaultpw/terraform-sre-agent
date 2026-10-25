# What this module must never loosen: the repository's code runs with no permissions and no
# inbound, the poller can do exactly four things, and an image that is not pinned by digest is
# refused before anything is planned. Plans run against mocked providers, so no credentials,
# network or state are used.

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
      arn                  = "arn:aws:ecs:us-east-1:123456789012:task-definition/mock:1"
      arn_without_revision = "arn:aws:ecs:us-east-1:123456789012:task-definition/mock"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:/mock"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:123456789012:function:mock"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/mock"
    }
  }
}

mock_provider "archive" {
  mock_data "archive_file" {
    defaults = {
      output_path         = ".build/poller.zip"
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
  sre_agent_url      = "https://sre.example.com"
  api_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-agent-verifier-key-AbCdEf"
  availability_zones = ["us-east-1a", "us-east-1b"]
  images = {
    node   = "ghcr.io/segfaultpw/sre-agent-verifier-node@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    python = "ghcr.io/segfaultpw/sre-agent-verifier-python@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
}

run "one_task_definition_per_runtime_sized_for_the_largest_class" {
  command = apply

  assert {
    condition     = toset(keys(aws_ecs_task_definition.verifier)) == toset(["node", "python"])
    error_message = "one task definition per runtime that was given an image"
  }

  assert {
    condition = alltrue([
      for definition in values(aws_ecs_task_definition.verifier) :
      definition.cpu == "4096" && definition.memory == "8192" && definition.network_mode == "awsvpc"
    ])
    error_message = "the largest class SRE Agent asks for is 4 vCPU and 8 GiB, in awsvpc mode"
  }

  assert {
    condition     = aws_ecs_task_definition.verifier["node"].runtime_platform[0].cpu_architecture == "X86_64"
    error_message = "x86_64 unless asked otherwise"
  }
}

run "the_code_runs_with_a_role_that_has_no_permissions" {
  command = apply

  # The execution role pulls the image and writes logs. The task role, which the repository's
  # code runs as, is a role with nothing attached: this module wires exactly one inline policy
  # to the execution role and one to the poller, and no managed policy to anything.
  assert {
    condition     = aws_iam_role_policy.execution.role == aws_iam_role.execution.id
    error_message = "the execution role's policy is the module's own inline one"
  }

  assert {
    condition     = length(aws_iam_role.execution.managed_policy_arns) == 0
    error_message = "no AWS managed policy (they are granted on every resource) on the execution role"
  }

  assert {
    condition     = aws_iam_role_policy.poller.role == aws_iam_role.poller.id
    error_message = "the only other inline policy goes to the poller"
  }

  assert {
    condition     = alltrue([for definition in values(aws_ecs_task_definition.verifier) : definition.task_role_arn == aws_iam_role.task.arn])
    error_message = "every task definition runs as the permissionless task role"
  }

  # Nothing is attached to or embedded in the task role itself either, which the
  # attachment and policy resources above cannot show.
  assert {
    condition     = length(aws_iam_role.task.managed_policy_arns) == 0
    error_message = "the task role has no managed policies"
  }

  assert {
    condition     = length(aws_iam_role.task.inline_policy) == 0
    error_message = "the task role has no inline policies"
  }

  assert {
    condition     = aws_iam_role.task.permissions_boundary == null
    error_message = "the task role is not given a boundary that a later edit could widen"
  }
}

run "the_execution_role_writes_the_task_logs_and_nothing_else" {
  command = apply

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Action
    ])) == toset(["logs:CreateLogStream", "logs:PutLogEvents"])
    error_message = "without a private ECR repository the execution role only writes its log stream (ghcr.io needs no AWS permission)"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement :
      flatten([s.Resource]) == ["${aws_cloudwatch_log_group.tasks.arn}:*"]
    ])
    error_message = "the task log group only, not every log group"
  }
}

run "private_ecr_repositories_are_read_only_when_named" {
  command = apply

  variables {
    ecr_repository_arns = ["arn:aws:ecr:us-east-1:123456789012:repository/verifier-node"]
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Action
      ])) == toset([
      "logs:CreateLogStream", "logs:PutLogEvents", "ecr:GetAuthorizationToken",
      "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability",
    ])
    error_message = "pull actions only, on the named repositories"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if contains(flatten([s.Action]), "ecr:BatchGetImage")
    ][0] == ["arn:aws:ecr:us-east-1:123456789012:repository/verifier-node"]
    error_message = "the pull actions are on the named repositories, not on every repository"
  }
}

run "an_ecr_repository_entry_that_is_not_an_arn_is_refused" {
  command = plan

  variables {
    ecr_repository_arns = ["*"]
  }

  expect_failures = [var.ecr_repository_arns]
}

run "the_ecs_roles_trust_ecs_tasks_of_this_account_only" {
  command = apply

  assert {
    condition = alltrue([
      for role in [aws_iam_role.execution, aws_iam_role.task] :
      jsondecode(role.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com"
    ])
    error_message = "the two ECS roles are assumed by ECS tasks"
  }

  assert {
    condition = alltrue([
      for role in [aws_iam_role.execution, aws_iam_role.task] :
      jsondecode(role.assume_role_policy).Statement[0].Condition == {
        StringEquals = { "aws:SourceAccount" = "123456789012" }
        ArnLike      = { "aws:SourceArn" = "arn:aws:ecs:us-east-1:123456789012:*" }
      }
    ])
    error_message = "confused-deputy conditions: this account, and ECS in this account and Region"
  }

  assert {
    condition     = jsondecode(aws_iam_role.poller.assume_role_policy).Statement[0].Principal.Service == "lambda.amazonaws.com"
    error_message = "the poller role is assumed by Lambda"
  }
}

run "the_poller_can_do_four_things_and_nothing_is_a_wildcard" {
  command = apply

  assert {
    condition = toset([
      for s in jsondecode(aws_iam_role_policy.poller.policy).Statement : s.Sid
    ]) == toset(["WriteItsOwnLogs", "ReadTheApiKey", "StartVerifierTasks", "PassTheTwoTaskRoles"])
    error_message = "logs, the one secret, RunTask on the verifier definitions, PassRole on the two roles"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.poller.policy).Statement :
      !contains(flatten([s.Resource]), "*")
    ])
    error_message = "no statement is granted on every resource"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.poller.policy).Statement : s.Condition if s.Sid == "PassTheTwoTaskRoles"
    ][0] == { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
    error_message = "PassRole is only to ECS tasks"
  }

  assert {
    condition = contains(keys([
      for s in jsondecode(aws_iam_role_policy.poller.policy).Statement : s.Condition if s.Sid == "StartVerifierTasks"
    ][0].ArnEquals), "ecs:cluster")
    error_message = "RunTask is limited to the verifier cluster"
  }

  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_role_policy.poller.policy).Statement : s.Action])) == toset(["logs:CreateLogStream", "logs:PutLogEvents", "secretsmanager:GetSecretValue", "ecs:RunTask", "iam:PassRole"])
    error_message = "the poller's whole action list"
  }
}

run "a_customer_managed_key_adds_decrypt_on_that_key_only" {
  command = apply

  variables {
    api_key_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.poller.policy).Statement : s.Resource if s.Sid == "DecryptTheApiKey"
    ][0] == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "kms:Decrypt on the one key"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.poller.policy).Statement : s.Condition if s.Sid == "DecryptTheApiKey"
      ][0] == {
      StringEquals = {
        "kms:ViaService"                  = "secretsmanager.us-east-1.amazonaws.com"
        "kms:EncryptionContext:SecretARN" = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-agent-verifier-key-AbCdEf"
      }
    }
    error_message = "the key decrypts only through Secrets Manager and only for the one secret"
  }
}

run "a_kms_key_that_is_not_a_key_arn_is_refused" {
  command = plan

  variables {
    api_key_kms_key_arn = "alias/aws/secretsmanager"
  }

  expect_failures = [var.api_key_kms_key_arn]
}

run "a_kms_alias_arn_is_refused_because_iam_needs_the_key" {
  command = plan

  variables {
    api_key_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:alias/mine"
  }

  expect_failures = [var.api_key_kms_key_arn]
}

run "the_network_has_no_inbound_and_https_out" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_egress_rule.https.from_port == 443 && aws_vpc_security_group_egress_rule.https.to_port == 443 && aws_vpc_security_group_egress_rule.https.ip_protocol == "tcp"
    error_message = "outbound HTTPS only"
  }

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "a private subnet per zone"
  }

  assert {
    condition     = alltrue([for subnet in aws_subnet.private : subnet.map_public_ip_on_launch == false || subnet.map_public_ip_on_launch == null])
    error_message = "tasks get no public address"
  }
}

# Fargate pulls the image and ships the logs through the task's own network interface and ignores
# HTTPS_PROXY, so the group must always reach the registry and CloudWatch Logs: egress is the
# internet on 443 and is not a variable (narrowing it to a proxy's address stopped every task).
run "egress_is_https_to_anywhere_and_nothing_else" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_egress_rule.https.cidr_ipv4 == "0.0.0.0/0"
    error_message = "the image pull and the log delivery need the internet"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.https.from_port == 443 && aws_vpc_security_group_egress_rule.https.to_port == 443 && aws_vpc_security_group_egress_rule.https.ip_protocol == "tcp"
    error_message = "443 only"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.verifier["node"].container_definitions)[0].environment == []
    error_message = "no proxy variables unless a proxy is given"
  }
}

run "a_proxy_reaches_the_commands_the_runner_runs" {
  command = apply

  variables {
    https_proxy = "https://proxy.internal:443"
  }

  assert {
    condition = toset([
      for e in jsondecode(aws_ecs_task_definition.verifier["node"].container_definitions)[0].environment : e.name
    ]) == toset(["HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"])
    error_message = "the proxy reaches the commands the runner runs"
  }

  assert {
    condition = [
      for e in jsondecode(aws_ecs_task_definition.verifier["node"].container_definitions)[0].environment : e.value if e.name == "NO_PROXY"
    ][0] == "localhost,127.0.0.1,::1"
    error_message = "loopback in both families is never sent to the proxy"
  }
}

run "the_poller_is_told_where_everything_is" {
  command = apply

  assert {
    condition     = aws_lambda_function.poller.environment[0].variables.SRE_AGENT_URL == "https://sre.example.com"
    error_message = "the origin"
  }

  assert {
    condition     = toset(keys(jsondecode(aws_lambda_function.poller.environment[0].variables.TASK_DEFINITIONS))) == toset(["node", "python"])
    error_message = "a task definition per runtime"
  }

  assert {
    condition     = output.queue_url == "https://sre.example.com/api/verifier/queue"
    error_message = "the queue address the Integrations page shows"
  }

  assert {
    condition     = output.api_key_scope == "verifier:poll"
    error_message = "the one scope"
  }
}

run "an_image_that_is_not_pinned_by_digest_is_refused" {
  command = plan

  variables {
    images = {
      node = "ghcr.io/segfaultpw/sre-agent-verifier-node:latest"
    }
  }

  expect_failures = [var.images]
}

run "a_runtime_nobody_verifies_is_refused" {
  command = plan

  variables {
    images = {
      ruby = "ghcr.io/example/ruby@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }

  expect_failures = [var.images]
}

run "the_origin_is_https_with_no_path" {
  command = plan

  variables {
    sre_agent_url = "http://sre.example.com/app"
  }

  expect_failures = [var.sre_agent_url]
}

# Overlapping polls are safe (the platform hands a job out with one conditional write, so the
# second of two simultaneous polls is given nothing and starts nothing), and a reservation fails
# to apply on an account whose total Lambda concurrency is still the new-account 10. So no
# reservation unless it is asked for.
run "the_poller_reserves_no_concurrency_by_default" {
  command = apply

  assert {
    condition     = aws_lambda_function.poller.reserved_concurrent_executions == null || aws_lambda_function.poller.reserved_concurrent_executions == -1
    error_message = "an unset reservation must not take concurrency from a small account"
  }
}

run "a_reservation_is_wired_when_asked_for" {
  command = apply

  variables {
    poller_reserved_concurrency = 1
  }

  assert {
    condition     = aws_lambda_function.poller.reserved_concurrent_executions == 1
    error_message = "poller_reserved_concurrency reaches the function"
  }
}

run "a_reservation_of_zero_would_stop_every_poll_and_is_refused" {
  command = plan

  variables {
    poller_reserved_concurrency = 0
  }

  expect_failures = [var.poller_reserved_concurrency]
}

run "a_failed_poll_is_not_retried_by_lambda" {
  command = apply

  assert {
    condition     = aws_lambda_function_event_invoke_config.poller.maximum_retry_attempts == 0
    error_message = "the next scheduled poll is the retry"
  }

  assert {
    condition     = aws_lambda_function_event_invoke_config.poller.function_name == aws_lambda_function.poller.function_name
    error_message = "the setting belongs to the poller"
  }
}

run "no_alarm_is_built_without_somewhere_to_send_it" {
  command = apply

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.poller_errors) == 0 && length(aws_cloudwatch_metric_alarm.poller_error_lines) == 0
    error_message = "alarm_actions defaults to none"
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.poller_error_lines) == 0
    error_message = "no metric is published when nobody is notified"
  }
}

run "poller_errors_alarm_when_given_actions" {
  command = apply

  variables {
    alarm_actions = ["arn:aws:sns:us-east-1:123456789012:oncall"]
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.poller_errors) == 1
    error_message = "one alarm"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.poller_errors[0].namespace == "AWS/Lambda" && aws_cloudwatch_metric_alarm.poller_errors[0].metric_name == "Errors"
    error_message = "the alarm is on the poller's Errors metric, which a refused key, an unreachable platform and an unreadable answer all raise"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.poller_errors[0].alarm_actions == toset(["arn:aws:sns:us-east-1:123456789012:oncall"])
    error_message = "the actions reach the alarm"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.poller_errors[0].dimensions.FunctionName == aws_lambda_function.poller.function_name
    error_message = "the alarm watches this function"
  }
}

# The poller logs a 426 (an image to upgrade, a poller too old), a refused RunTask and a missing
# task definition at level error and returns normally, so Lambda's Errors never counts them.
# test_log_filter.py pins the pattern to what poller.py prints.
run "the_error_lines_the_poller_logs_without_raising_have_their_own_alarm" {
  command = apply

  variables {
    alarm_actions = ["arn:aws:sns:us-east-1:123456789012:oncall"]
  }

  assert {
    condition     = aws_cloudwatch_log_metric_filter.poller_error_lines[0].pattern == "{ $.level = \"error\" }"
    error_message = "the filter matches the poller's level=error JSON lines"
  }

  assert {
    condition     = aws_cloudwatch_log_metric_filter.poller_error_lines[0].log_group_name == aws_cloudwatch_log_group.poller.name
    error_message = "the filter reads the poller's log group"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.poller_error_lines[0].metric_name == aws_cloudwatch_log_metric_filter.poller_error_lines[0].metric_transformation[0].name && aws_cloudwatch_metric_alarm.poller_error_lines[0].namespace == aws_cloudwatch_log_metric_filter.poller_error_lines[0].metric_transformation[0].namespace
    error_message = "the alarm watches the filter's metric"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.poller_error_lines[0].alarm_actions == toset(["arn:aws:sns:us-east-1:123456789012:oncall"])
    error_message = "the same actions as the Errors alarm"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.poller_error_lines[0].treat_missing_data == "notBreaching"
    error_message = "no error line is no problem"
  }
}

run "the_poller_timeout_covers_its_worst_path" {
  command = apply

  # A refused key costs two polls of up to 20 s each, a secret read between them and a RunTask:
  # a timeout that ends the invocation after a job was handed out loses that job.
  assert {
    condition     = aws_lambda_function.poller.timeout == 60
    error_message = "60 seconds: two 20 s polls, the secret read and the RunTask"
  }
}

run "more_than_three_zones_are_refused" {
  command = plan

  variables {
    availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  }

  expect_failures = [var.availability_zones]
}

run "an_empty_zone_list_is_refused" {
  command = plan

  variables {
    availability_zones = []
  }

  expect_failures = [var.availability_zones]
}

run "the_key_comes_from_a_secret_not_from_state" {
  command = plan

  variables {
    api_key_secret_arn = "sre_ak_the_key_itself"
  }

  expect_failures = [var.api_key_secret_arn]
}

run "a_partial_secret_arn_is_refused" {
  command = plan

  variables {
    api_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-agent-verifier-key"
  }

  expect_failures = [var.api_key_secret_arn]
}

run "a_secret_in_another_region_is_refused" {
  command = plan

  variables {
    api_key_secret_arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:sre-agent-verifier-key-AbCdEf"
  }

  expect_failures = [aws_lambda_function.poller]
}

run "a_poll_schedule_the_platform_would_call_stale_is_refused" {
  command = plan

  variables {
    poll_schedule_expression = "rate(10 minutes)"
  }

  expect_failures = [var.poll_schedule_expression]
}

run "an_hourly_poll_schedule_is_refused" {
  command = plan

  variables {
    poll_schedule_expression = "rate(1 hour)"
  }

  expect_failures = [var.poll_schedule_expression]
}

run "a_cron_poll_schedule_is_refused_because_its_interval_cannot_be_checked" {
  command = plan

  variables {
    poll_schedule_expression = "cron(0/10 * * * ? *)"
  }

  expect_failures = [var.poll_schedule_expression]
}

run "a_five_minute_poll_schedule_is_the_slowest_accepted" {
  command = apply

  variables {
    poll_schedule_expression = "rate(5 minutes)"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.poll.schedule_expression == "rate(5 minutes)"
    error_message = "the platform treats a poller as alive for 5 minutes"
  }
}

run "a_retention_cloudwatch_does_not_offer_is_refused" {
  command = plan

  variables {
    log_retention_days = 45
  }

  expect_failures = [var.log_retention_days]
}

run "a_retention_cloudwatch_offers_reaches_both_log_groups" {
  command = apply

  variables {
    log_retention_days = 90
  }

  assert {
    condition     = aws_cloudwatch_log_group.tasks.retention_in_days == 90 && aws_cloudwatch_log_group.poller.retention_in_days == 90
    error_message = "both log groups"
  }
}

run "a_vpc_cidr_without_a_prefix_is_refused_with_the_message" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0"
  }

  expect_failures = [var.vpc_cidr]
}

run "a_vpc_cidr_larger_than_aws_allows_is_refused" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/15"
  }

  expect_failures = [var.vpc_cidr]
}

run "log_groups_use_the_default_encryption_unless_a_key_is_given" {
  command = apply

  assert {
    condition     = aws_cloudwatch_log_group.tasks.kms_key_id == null && aws_cloudwatch_log_group.poller.kms_key_id == null
    error_message = "no key, no override"
  }
}

run "a_customer_managed_key_encrypts_both_log_groups" {
  command = apply

  variables {
    log_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = aws_cloudwatch_log_group.tasks.kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" && aws_cloudwatch_log_group.poller.kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "test output from customer repositories lands in the task log group"
  }
}

run "a_log_key_that_is_not_a_key_arn_is_refused" {
  command = plan

  variables {
    log_kms_key_arn = "my-key"
  }

  expect_failures = [var.log_kms_key_arn]
}
