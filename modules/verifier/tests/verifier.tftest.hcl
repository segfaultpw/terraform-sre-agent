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
  target = data.aws_iam_policy_document.ecs_tasks_assume
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

override_data {
  target = data.aws_iam_policy_document.lambda_assume
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
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
  # code runs as, is a role with nothing attached: this module wires exactly one policy
  # attachment (to the execution role) and one inline policy (to the poller).
  assert {
    condition     = aws_iam_role_policy_attachment.execution.role == aws_iam_role.execution.name
    error_message = "the only managed policy goes to the execution role"
  }

  assert {
    condition     = aws_iam_role_policy.poller.role == aws_iam_role.poller.id
    error_message = "the only inline policy goes to the poller"
  }

  assert {
    condition     = alltrue([for definition in values(aws_ecs_task_definition.verifier) : definition.task_role_arn == aws_iam_role.task.arn])
    error_message = "every task definition runs as the permissionless task role"
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
}

run "the_network_has_no_inbound_and_https_out" {
  command = apply

  assert {
    condition     = alltrue([for rule in values(aws_vpc_security_group_egress_rule.https) : rule.from_port == 443 && rule.to_port == 443 && rule.ip_protocol == "tcp"])
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

run "egress_can_be_narrowed_to_a_proxy" {
  command = apply

  variables {
    egress_cidrs = ["10.9.0.0/28"]
    https_proxy  = "http://proxy.internal:3128"
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_egress_rule.https)) == toset(["10.9.0.0/28"])
    error_message = "only the proxy is reachable"
  }

  assert {
    condition = contains(
      [for e in jsondecode(aws_ecs_task_definition.verifier["node"].container_definitions)[0].environment : e.name],
      "HTTPS_PROXY"
    )
    error_message = "the proxy reaches the commands the runner runs"
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
    condition     = aws_lambda_function.poller.reserved_concurrent_executions == 1
    error_message = "one poll at a time"
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

run "the_key_comes_from_a_secret_not_from_state" {
  command = plan

  variables {
    api_key_secret_arn = "sre_ak_the_key_itself"
  }

  expect_failures = [var.api_key_secret_arn]
}
