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

## The service
run "a_model_without_a_provider_prefix_is_refused" {
  command = plan

  variables {
    sre_model = "deepseek-v4-pro"
  }

  expect_failures = [var.sre_model]
}

## GitHub authentication: a GitHub App or static tokens, one shape exactly

run "app_mode_sets_the_app_id_and_carries_the_key" {
  command = apply

  variables {
    github_token_secret_arn           = null
    github_app_id                     = "123456"
    github_app_private_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-app-key-QqRrSs"
  }

  assert {
    condition = {
      for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value
      } == {
      SRE_SERVER_URL     = "https://sre.example.com"
      SRE_MODEL          = "openrouter/deepseek/deepseek-v4-pro"
      SRE_WORKSPACE      = "/workspace"
      SRE_MEMORY_BUCKET  = "sre-agent-fix-runner-memory-123456789012-us-east-1"
      SRE_MEMORY_PREFIX  = "memory/"
      SRE_GITHUB_APP_ID  = "123456"
      AWS_REGION         = "us-east-1"
      AWS_DEFAULT_REGION = "us-east-1"
    }
    error_message = "App mode adds exactly SRE_GITHUB_APP_ID as a plain value; the id is not a secret"
  }

  assert {
    condition = {
      for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.name => s.valueFrom
      } == {
      SRE_API_KEY                = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-key-AbCdEf"
      SRE_GITHUB_APP_PRIVATE_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-app-key-QqRrSs"
      OPENROUTER_API_KEY         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr"
    }
    error_message = "the App's key is injected as SRE_GITHUB_APP_PRIVATE_KEY and neither static token exists in App mode"
  }

  assert {
    condition = contains(flatten([
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "ReadTheSecrets"
    ]), "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-app-key-QqRrSs")
    error_message = "the execution role may read the App key's secret"
  }
}

run "pat_mode_sets_neither_app_variable" {
  command = apply

  assert {
    condition     = !contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name], "SRE_GITHUB_APP_ID")
    error_message = "the token shape sets no App variable"
  }

  assert {
    condition     = !contains([for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.name], "SRE_GITHUB_APP_PRIVATE_KEY")
    error_message = "the token shape carries no App key"
  }
}

run "both_github_shapes_at_once_is_refused" {
  command = plan

  variables {
    github_app_id                     = "123456"
    github_app_private_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-app-key-QqRrSs"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "the_app_with_the_agent_token_is_refused" {
  command = plan

  variables {
    github_token_secret_arn           = null
    github_app_id                     = "123456"
    github_app_private_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-app-key-QqRrSs"
    agent_github_token_secret_arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:agent-readonly-StUvWx"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "neither_github_shape_is_refused" {
  command = plan

  variables {
    github_token_secret_arn = null
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "the_app_id_without_its_key_is_refused" {
  command = plan

  variables {
    github_token_secret_arn = null
    github_app_id           = "123456"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "the_app_key_without_its_id_is_refused" {
  command = plan

  variables {
    github_token_secret_arn           = null
    github_app_private_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-app-key-QqRrSs"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "an_app_id_that_is_not_numeric_is_refused" {
  command = plan

  variables {
    github_token_secret_arn           = null
    github_app_id                     = "acme-fix-bot"
    github_app_private_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-app-key-QqRrSs"
  }

  expect_failures = [var.github_app_id]
}

run "a_partial_app_key_arn_is_refused" {
  command = plan

  variables {
    github_token_secret_arn           = null
    github_app_id                     = "123456"
    github_app_private_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-app-key"
  }

  expect_failures = [var.github_app_private_key_secret_arn]
}

run "a_secret_in_another_region_is_refused_for_the_app_key" {
  command = plan

  variables {
    github_token_secret_arn           = null
    github_app_id                     = "123456"
    github_app_private_key_secret_arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:sre-fix-runner-app-key-QqRrSs"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_pool_in_app_mode_keeps_the_pool_variables" {
  command = apply

  variables {
    runner_count                      = 2
    github_token_secret_arn           = null
    github_app_id                     = "123456"
    github_app_private_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-app-key-QqRrSs"
  }

  assert {
    condition = {
      for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value
      if contains(["SRE_GITHUB_APP_ID", "SRE_WORKSPACE_PER_INSTANCE", "SRE_MEMORY_ROOT"], e.name)
      } == {
      SRE_GITHUB_APP_ID          = "123456"
      SRE_WORKSPACE_PER_INSTANCE = "1"
      SRE_MEMORY_ROOT            = "/workspace/memory"
    }
    error_message = "App mode changes nothing about the pool: the App id and both pool variables are set together"
  }
}

## The task role

run "the_task_role_holds_the_workspace_the_memory_prefix_and_nothing_else" {
  command = apply

  assert {
    condition = toset([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid
    ]) == toset(["MountTheWorkspace", "ListTheMemoryPrefix", "ReadWriteAndDeleteTheMemoryPrefix"])
    error_message = "the access point, the list and the objects under the prefix"
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Action
      ])) == toset([
      "elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess",
      "s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
    ])
    error_message = "the task role's whole action list"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      !contains(flatten([s.Resource]), "*")
    ])
    error_message = "no statement is on every resource"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Resource if s.Sid == "ReadWriteAndDeleteTheMemoryPrefix"
    ][0] == "arn:aws:s3:::sre-agent-fix-runner-memory-123456789012-us-east-1/memory/*"
    error_message = "objects under the memory prefix only"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Resource if s.Sid == "ListTheMemoryPrefix"
    ][0] == "arn:aws:s3:::sre-agent-fix-runner-memory-123456789012-us-east-1"
    error_message = "the list is on the bucket"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Condition if s.Sid == "ListTheMemoryPrefix"
    ][0] == { StringLike = { "s3:prefix" = ["memory/*"] } }
    error_message = "and limited to the prefix"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Condition if s.Sid == "MountTheWorkspace"
    ][0] == { StringEquals = { "elasticfilesystem:AccessPointArn" = aws_efs_access_point.this.arn } }
    error_message = "the file system is reachable only through the module's access point"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Resource if s.Sid == "MountTheWorkspace"
    ][0] == aws_efs_file_system.this.arn
    error_message = "on the one file system"
  }

  assert {
    condition     = length(aws_iam_role.task.managed_policy_arns) == 0 && length(aws_iam_role.task.inline_policy) == 0
    error_message = "nothing is embedded in the role itself"
  }

  assert {
    condition     = aws_iam_role.task.permissions_boundary == null
    error_message = "no boundary a later edit could widen"
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.extra) == 0
    error_message = "by default no policy is attached to the task role"
  }
}

run "the_task_role_is_given_exactly_the_policies_the_operator_names" {
  command = apply

  variables {
    extra_policy_arns = [
      "arn:aws:iam::aws:policy/ReadOnlyAccess",
      "arn:aws:iam::123456789012:policy/runner-reads-logs",
    ]
  }

  assert {
    condition     = tolist([for a in aws_iam_role_policy_attachment.extra : a.policy_arn]) == var.extra_policy_arns
    error_message = "exactly extra_policy_arns, one attachment each, in the order given"
  }

  assert {
    condition     = alltrue([for a in aws_iam_role_policy_attachment.extra : a.role == aws_iam_role.task.name])
    error_message = "attached to the task role, not to the execution role"
  }
}

run "a_policy_made_in_the_same_configuration_can_be_attached_on_the_first_apply" {
  command = plan

  module {
    source = "./tests/with_policy"
  }

  override_data {
    target = module.runner.data.aws_partition.current
    values = {
      partition = "aws"
    }
  }

  override_data {
    target = module.runner.data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  assert {
    condition     = length(module.runner.task_role_name) > 0
    error_message = "the plan is built even though the policy's ARN is not known until it is created"
  }
}

run "the_same_extra_policy_twice_is_refused" {
  command = plan

  variables {
    extra_policy_arns = [
      "arn:aws:iam::aws:policy/ReadOnlyAccess",
      "arn:aws:iam::aws:policy/ReadOnlyAccess",
    ]
  }

  expect_failures = [var.extra_policy_arns]
}

run "an_extra_policy_that_is_not_an_arn_is_refused" {
  command = plan

  variables {
    extra_policy_arns = ["AdministratorAccess"]
  }

  expect_failures = [var.extra_policy_arns]
}

run "the_ecs_roles_trust_ecs_tasks_of_this_account_only" {
  command = apply

  assert {
    condition = alltrue([
      for role in [aws_iam_role.execution, aws_iam_role.task] :
      jsondecode(role.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com"
    ])
    error_message = "both roles are assumed by ECS tasks"
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
    condition     = aws_ecs_task_definition.this.task_role_arn == aws_iam_role.task.arn && aws_ecs_task_definition.this.execution_role_arn == aws_iam_role.execution.arn
    error_message = "the task definition names the two roles"
  }
}

## The agent's AWS access

run "the_agent_has_no_aws_access_unless_it_is_asked_for" {
  command = apply

  assert {
    condition     = !contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name], "SRE_AGENT_AWS_ACCESS")
    error_message = "unset, so the runner takes the AWS credentials out of the agent's environment"
  }
}

run "agent_aws_access_false_sets_nothing_either" {
  command = apply

  variables {
    agent_aws_access = false
  }

  assert {
    condition     = !contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name], "SRE_AGENT_AWS_ACCESS")
    error_message = "false is the absence of the variable, not SRE_AGENT_AWS_ACCESS=0"
  }
}

run "agent_aws_access_true_sets_the_one_value_the_runner_accepts" {
  command = apply

  variables {
    agent_aws_access = true
  }

  assert {
    condition = [
      for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.value if e.name == "SRE_AGENT_AWS_ACCESS"
    ] == ["1"]
    error_message = "only the exact value 1 opts in"
  }
}

## Extra environment

run "an_extra_variable_reaches_the_container" {
  command = apply

  variables {
    extra_environment = {
      SRE_RUNNER_SETUP = "/opt/setup.sh"
      SRE_LOG_LEVEL    = "debug"
    }
  }

  assert {
    condition = {
      for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value
      if contains(["SRE_RUNNER_SETUP", "SRE_LOG_LEVEL"], e.name)
    } == { SRE_RUNNER_SETUP = "/opt/setup.sh", SRE_LOG_LEVEL = "debug" }
    error_message = "extra_environment is passed through"
  }

  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment) == 9
    error_message = "the seven the module sets and the two extras"
  }
}

run "extra_environment_cannot_replace_what_the_module_sets" {
  command = plan

  variables {
    extra_environment = { SRE_SERVER_URL = "https://elsewhere.example.com" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_the_pool_workspace_split_in_a_pool" {
  command = plan

  variables {
    runner_count      = 2
    extra_environment = { SRE_WORKSPACE_PER_INSTANCE = "1" }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "extra_environment_cannot_set_the_pool_memory_root_in_a_pool" {
  command = plan

  variables {
    runner_count      = 3
    extra_environment = { SRE_MEMORY_ROOT = "/workspace/memory" }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "extra_environment_cannot_set_one_shared_identity_in_a_pool" {
  command = plan

  variables {
    runner_count      = 2
    extra_environment = { SRE_RUNNER_INSTANCE = "shared" }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_pool_refuses_the_image_that_cannot_lease" {
  command = plan

  variables {
    runner_count = 2
    image        = "ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:ef95a56a8ae2763e7c9b1a98e261443a4489ca78ba449d47331f3d7a163b1b52"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_pool_refuses_the_v1_5_0_digest_with_a_tag_spelling" {
  command = plan

  variables {
    runner_count = 2
    image        = "ghcr.io/segfaultpw/sre-agent-opencode-runner:v1.5.0@sha256:ef95a56a8ae2763e7c9b1a98e261443a4489ca78ba449d47331f3d7a163b1b52"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_pool_refuses_the_v1_5_0_digest_under_a_mirror_name" {
  command = plan

  variables {
    runner_count = 2
    image        = "123456789012.dkr.ecr.us-east-1.amazonaws.com/fix-runner@sha256:ef95a56a8ae2763e7c9b1a98e261443a4489ca78ba449d47331f3d7a163b1b52"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_pool_accepts_an_image_the_module_does_not_know" {
  command = plan

  variables {
    runner_count = 2
    image        = "ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].image == "ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    error_message = "a pool accepts an explicit image digest other than the lease-incapable v1.5.0 one; the operator vouches for it"
  }
}

run "at_one_task_the_pool_variables_stay_the_operator_s" {
  command = apply

  variables {
    extra_environment = { SRE_WORKSPACE_PER_INSTANCE = "1", SRE_MEMORY_ROOT = "/workspace/memory" }
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_WORKSPACE_PER_INSTANCE"] == "1"
    error_message = "at runner_count 1 the module sets neither pool variable, so the operator's SRE_WORKSPACE_PER_INSTANCE reaches the runner as in 4.2.0"
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_MEMORY_ROOT"] == "/workspace/memory"
    error_message = "at runner_count 1 the module sets neither pool variable, so the operator's SRE_MEMORY_ROOT reaches the runner as in 4.2.0"
  }
}

run "extra_environment_cannot_set_the_memory_bucket" {
  command = plan

  variables {
    extra_environment = { SRE_MEMORY_BUCKET = "someone-elses-bucket" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_the_agent_aws_switch" {
  command = plan

  variables {
    extra_environment = { SRE_AGENT_AWS_ACCESS = "1" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_carry_a_secret_the_module_carries_as_one" {
  command = plan

  variables {
    extra_environment = { SRE_API_KEY = "sre_ak_the_key_itself" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_carry_the_github_token" {
  command = plan

  variables {
    extra_environment = { SRE_GITHUB_TOKEN = "ghp_the_token_itself" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_carry_the_agent_token" {
  command = plan

  variables {
    extra_environment = { SRE_AGENT_GITHUB_TOKEN = "ghp_the_token_itself" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_carry_the_app_private_key" {
  command = plan

  variables {
    extra_environment = { SRE_GITHUB_APP_PRIVATE_KEY = "-----BEGIN RSA PRIVATE KEY-----" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_the_app_id_in_app_mode" {
  command = plan

  variables {
    github_token_secret_arn           = null
    github_app_id                     = "123456"
    github_app_private_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-app-key-QqRrSs"
    extra_environment                 = { SRE_GITHUB_APP_ID = "999999" }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "extra_environment_cannot_carry_a_provider_key" {
  command = plan

  variables {
    extra_environment = { ANTHROPIC_API_KEY = "sk-ant-the-key-itself" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_refuses_registry_pass" {
  command = plan

  variables {
    extra_environment = { REGISTRY_PASS = "the-password" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_refuses_basic_auth" {
  command = plan

  variables {
    extra_environment = { BASIC_AUTH = "user:password" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_refuses_ssh_private" {
  command = plan

  variables {
    extra_environment = { SSH_PRIVATE = "-----BEGIN" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_refuses_sentry_dsn" {
  command = plan

  variables {
    extra_environment = { SENTRY_DSN = "https://key@sentry.example.com/1" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_refuses_database_url" {
  command = plan

  variables {
    extra_environment = { DATABASE_URL = "postgres://user:password@db/app" }
  }

  expect_failures = [var.extra_environment]
}
