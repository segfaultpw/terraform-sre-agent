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

## The service

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

run "three_tasks_share_one_volume_and_each_leases_its_own_jobs" {
  command = apply

  variables {
    runner_count = 3
  }

  assert {
    condition     = aws_ecs_service.this[0].desired_count == 3
    error_message = "runner_count is the service's desired count"
  }

  assert {
    condition     = aws_ecs_service.this[0].deployment_maximum_percent == 100 && aws_ecs_service.this[0].deployment_minimum_healthy_percent == 0
    error_message = "a deploy replaces the tasks one at a time, never more than the count at once"
  }

  assert {
    condition = {
      for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value
      } == {
      SRE_SERVER_URL             = "https://sre.example.com"
      SRE_MODEL                  = "openrouter/deepseek/deepseek-v4-pro"
      SRE_WORKSPACE              = "/workspace"
      SRE_MEMORY_BUCKET          = "sre-agent-fix-runner-memory-123456789012-us-east-1"
      SRE_MEMORY_PREFIX          = "memory/"
      SRE_WORKSPACE_PER_INSTANCE = "1"
      SRE_MEMORY_ROOT            = "/workspace/memory"
      AWS_REGION                 = "us-east-1"
      AWS_DEFAULT_REGION         = "us-east-1"
    }
    error_message = "above 1 the task definition gains exactly SRE_WORKSPACE_PER_INSTANCE=1 and SRE_MEMORY_ROOT=/workspace/memory, so each task works under instances/<its instance id> while the memory stays one shared tree"
  }
}

run "at_one_task_the_environment_holds_neither_pool_variable" {
  command = apply

  assert {
    condition     = !contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name], "SRE_WORKSPACE_PER_INSTANCE") && !contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name], "SRE_MEMORY_ROOT")
    error_message = "at runner_count 1 the environment is exactly the 4.2.0 shape: neither pool variable is set"
  }
}

run "a_runner_count_below_one_is_refused" {
  command = plan

  variables {
    runner_count = 0
  }

  expect_failures = [var.runner_count]
}

run "a_fractional_runner_count_is_refused" {
  command = plan

  variables {
    runner_count = 2.5
  }

  expect_failures = [var.runner_count]
}

run "the_runner_is_arm64_unless_asked_otherwise" {
  command = apply

  assert {
    condition     = aws_ecs_task_definition.this.runtime_platform[0].cpu_architecture == "ARM64"
    error_message = "ARM64 by default"
  }

  assert {
    condition     = aws_ecs_task_definition.this.requires_compatibilities == toset(["FARGATE"]) && aws_ecs_task_definition.this.network_mode == "awsvpc"
    error_message = "Fargate in awsvpc mode"
  }
}

run "x86_64_is_accepted_and_nothing_else_is" {
  command = apply

  variables {
    cpu_architecture = "X86_64"
  }

  assert {
    condition     = aws_ecs_task_definition.this.runtime_platform[0].cpu_architecture == "X86_64"
    error_message = "the published image is multi-architecture"
  }
}

run "an_unknown_cpu_architecture_is_refused" {
  command = plan

  variables {
    cpu_architecture = "arm64"
  }

  expect_failures = [var.cpu_architecture]
}

## The container

# The image starts as root so that its entrypoint can run every agent run as a second account, and
# the six capabilities that needs are in Fargate's default set. Setting a user, or dropping
# capabilities, would stop the runner from starting.
run "the_container_starts_as_root_and_keeps_the_default_capabilities" {
  command = apply

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.this.container_definitions)[0]), "user")
    error_message = "no user: the image's entrypoint switches to the runner and agent accounts itself"
  }

  assert {
    condition     = !contains(keys(try(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].linuxParameters, {})), "capabilities")
    error_message = "no capabilities block: SETUID, SETGID, CHOWN, DAC_OVERRIDE, FOWNER and KILL stay in Fargate's default set"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].linuxParameters.initProcessEnabled == true
    error_message = "an init process reaps what a killed agent run leaves behind"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].stopTimeout == 120
    error_message = "Fargate's longest stop time, a ceiling and not a wait: today the runner exits on SIGTERM at once, and a runner release that finishes the request in flight on SIGTERM needs the time"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].essential == true
    error_message = "essential"
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.this.container_definitions)[0]), "portMappings")
    error_message = "no port: the runner dials out and nothing dials in"
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.this.container_definitions)[0]), "readonlyRootFilesystem")
    error_message = "the agent writes under /tmp and its home, so the root filesystem stays writable"
  }
}

run "the_image_is_the_one_that_was_given_by_digest" {
  command = apply

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].image == var.image
    error_message = "the digest reaches the task definition unchanged"
  }
}

run "an_image_tag_is_refused" {
  command = plan

  variables {
    image = "ghcr.io/segfaultpw/sre-agent-opencode-runner:v1"
  }

  expect_failures = [var.image]
}

run "an_image_with_a_tag_and_a_digest_is_still_pinned_by_digest" {
  command = apply

  variables {
    image = "ghcr.io/segfaultpw/sre-agent-opencode-runner:v1.5.0@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].image == var.image
    error_message = "name:tag@sha256 is resolved by the digest"
  }
}

run "a_short_digest_is_refused" {
  command = plan

  variables {
    image = "ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:abc123"
  }

  expect_failures = [var.image]
}

run "the_default_image_is_the_current_runner_by_digest" {
  command = plan

  variables {
    image = null
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].image == "ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:6106650ffc929020021df7a50365826ec615652ba8fada26d4bf5695ab0143fd"
    error_message = "null means the default, the current runner pinned by its multi-architecture digest"
  }
}

run "the_runner_is_told_where_everything_is" {
  command = apply

  assert {
    condition = {
      for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value
      } == {
      SRE_SERVER_URL     = "https://sre.example.com"
      SRE_MODEL          = "openrouter/deepseek/deepseek-v4-pro"
      SRE_WORKSPACE      = "/workspace"
      SRE_MEMORY_BUCKET  = "sre-agent-fix-runner-memory-123456789012-us-east-1"
      SRE_MEMORY_PREFIX  = "memory/"
      AWS_REGION         = "us-east-1"
      AWS_DEFAULT_REGION = "us-east-1"
    }
    error_message = "the environment is exactly these seven plain values by default, and no secret value is among them"
  }
}

run "sizing_defaults_are_a_valid_fargate_pair" {
  command = apply

  assert {
    condition     = aws_ecs_task_definition.this.cpu == "2048" && aws_ecs_task_definition.this.memory == "8192"
    error_message = "2 vCPU and 8 GiB by default"
  }

  assert {
    condition     = aws_ecs_task_definition.this.ephemeral_storage[0].size_in_gib == 30
    error_message = "30 GiB of scratch beside the volume"
  }
}

run "a_memory_size_fargate_does_not_offer_for_the_cpu_is_refused" {
  command = plan

  variables {
    cpu    = 2048
    memory = 3072
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_memory_size_off_the_step_is_refused" {
  command = plan

  variables {
    cpu    = 8192
    memory = 18432
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_cpu_fargate_does_not_offer_is_refused" {
  command = plan

  variables {
    cpu = 3000
  }

  expect_failures = [var.cpu]
}

run "four_vcpu_and_sixteen_gib_is_accepted" {
  command = apply

  variables {
    cpu    = 4096
    memory = 16384
  }

  assert {
    condition     = aws_ecs_task_definition.this.cpu == "4096" && aws_ecs_task_definition.this.memory == "16384"
    error_message = "the sizing variables reach the task definition"
  }
}

## Secrets

run "the_execution_role_reads_only_the_named_secrets" {
  command = apply

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Action
    ])) == toset(["logs:CreateLogStream", "logs:PutLogEvents", "secretsmanager:GetSecretValue"])
    error_message = "write the log stream and read the secrets, nothing else (ghcr.io needs no AWS permission)"
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "ReadTheSecrets"
      ])) == toset([
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-key-AbCdEf",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-github-GhIjKl",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr",
    ])
    error_message = "exactly the API key, the GitHub token and the provider key"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement :
      !contains(flatten([s.Resource]), "*")
    ])
    error_message = "no statement is on every resource"
  }

  assert {
    condition     = length(aws_iam_role.execution.managed_policy_arns) == 0 && length(aws_iam_role.execution.inline_policy) == 0
    error_message = "nothing is embedded in the execution role itself"
  }

  # An aws_iam_role_policy_attachment does not show in the role's managed_policy_arns, so an
  # AWS managed execution policy (every log group and every repository) attached to this role
  # is only visible in the module's own text: the only attachment resource is "extra", for the
  # task role, and the only inline policies are "execution" and "task".
  assert {
    condition     = length(regexall("(?m)^resource \"aws_iam_role_policy_attachment\" ", file("${path.module}/main.tf"))) == 1 && length(regexall("(?m)^resource \"aws_iam_role_policy_attachment\" \"extra\" ", file("${path.module}/main.tf"))) == 1
    error_message = "the only policy attachment is extra, on the task role"
  }

  assert {
    condition     = length(regexall("(?m)^resource \"(aws_iam_policy_attachment|aws_iam_role_policies_exclusive|aws_iam_role_policy_attachments_exclusive|aws_security_group_rule)\" ", file("${path.module}/main.tf"))) == 0
    error_message = "no aws_iam_policy_attachment, exclusive attachment set or aws_security_group_rule: each reaches a role or a group without showing as one of the module's own rules"
  }

  assert {
    condition     = length(regexall("(?m)^resource \"aws_iam_role_policy\" ", file("${path.module}/main.tf"))) == 2 && length(regexall("(?m)^resource \"aws_iam_role_policy\" \"(execution|task)\" ", file("${path.module}/main.tf"))) == 2
    error_message = "the only inline policies are execution and task"
  }
}

run "the_secrets_reach_the_container_by_name_and_never_by_value" {
  command = apply

  assert {
    condition = {
      for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.name => s.valueFrom
      } == {
      SRE_API_KEY        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-key-AbCdEf"
      SRE_GITHUB_TOKEN   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-github-GhIjKl"
      OPENROUTER_API_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr"
    }
    error_message = "SRE_API_KEY, SRE_GITHUB_TOKEN and the provider key, each from its own secret"
  }
}

run "an_agent_token_adds_one_secret_and_one_grant" {
  command = apply

  variables {
    agent_github_token_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:agent-readonly-StUvWx"
  }

  assert {
    condition = [
      for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.valueFrom if s.name == "SRE_AGENT_GITHUB_TOKEN"
    ] == ["arn:aws:secretsmanager:us-east-1:123456789012:secret:agent-readonly-StUvWx"]
    error_message = "SRE_AGENT_GITHUB_TOKEN comes from its secret"
  }

  assert {
    condition = contains(flatten([
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "ReadTheSecrets"
    ]), "arn:aws:secretsmanager:us-east-1:123456789012:secret:agent-readonly-StUvWx")
    error_message = "the execution role may read it"
  }
}

run "without_an_agent_token_neither_the_variable_nor_the_grant_exists" {
  command = apply

  assert {
    condition     = !contains([for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.name], "SRE_AGENT_GITHUB_TOKEN")
    error_message = "unset, the agent holds the runner's token, which is the documented default"
  }

  assert {
    condition     = length(flatten([for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "ReadTheSecrets"])) == 3
    error_message = "three secrets are readable, not four"
  }
}

run "two_provider_keys_are_two_secrets" {
  command = apply

  variables {
    provider_key_secret_arns = {
      OPENROUTER_API_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr"
      ANTHROPIC_API_KEY  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:anthropic-key-YzAbCd"
    }
  }

  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets) == 4
    error_message = "the API key, the GitHub token and the two provider keys"
  }

  assert {
    condition     = length(flatten([for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "ReadTheSecrets"])) == 4
    error_message = "each is readable"
  }
}

run "a_customer_managed_key_adds_decrypt_through_secrets_manager_only" {
  command = apply

  variables {
    secrets_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Condition.StringEquals["kms:ViaService"] if s.Sid == "DecryptTheSecrets"
    ][0] == "secretsmanager.us-east-1.amazonaws.com"
    error_message = "kms:Decrypt only through Secrets Manager"
  }

  assert {
    condition = toset([
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Condition.StringEquals["kms:EncryptionContext:SecretARN"] if s.Sid == "DecryptTheSecrets"
      ][0]) == toset([
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-key-AbCdEf",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-github-GhIjKl",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr",
    ])
    error_message = "and only for these secrets"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "DecryptTheSecrets"
    ][0] == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "on the one key"
  }
}

run "a_kms_alias_is_refused_because_iam_needs_the_key" {
  command = plan

  variables {
    secrets_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:alias/mine"
  }

  expect_failures = [var.secrets_kms_key_arn]
}

run "a_partial_secret_arn_is_refused" {
  command = plan

  variables {
    api_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-key"
  }

  expect_failures = [var.api_key_secret_arn]
}

run "the_key_itself_is_refused_where_an_arn_is_wanted" {
  command = plan

  variables {
    github_token_secret_arn = "ghp_the_token_itself"
  }

  expect_failures = [var.github_token_secret_arn]
}

run "a_partial_agent_token_arn_is_refused" {
  command = plan

  variables {
    agent_github_token_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:agent-readonly"
  }

  expect_failures = [var.agent_github_token_secret_arn]
}

run "an_arn_whose_name_has_a_character_secrets_manager_forbids_is_refused" {
  command = plan

  variables {
    api_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:bad name-AbCdEf"
  }

  expect_failures = [var.api_key_secret_arn]
}

run "an_arn_whose_suffix_is_longer_than_six_characters_is_refused" {
  command = plan

  variables {
    github_token_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-github-GhIjKlM"
  }

  expect_failures = [var.github_token_secret_arn]
}

run "a_name_with_slashes_and_the_other_allowed_characters_is_accepted" {
  command = apply

  variables {
    api_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:team/sre.fix_runner+key=1@x-AbCdEf"
  }

  assert {
    condition     = contains([for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.valueFrom], var.api_key_secret_arn)
    error_message = "the name characters Secrets Manager allows are not refused"
  }
}

run "a_secret_in_another_region_is_refused_for_the_api_key" {
  command = plan

  variables {
    api_key_secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:sre-fix-runner-key-AbCdEf"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_secret_in_another_region_is_refused_for_the_github_token" {
  command = plan

  variables {
    github_token_secret_arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:sre-fix-runner-github-GhIjKl"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_secret_in_another_region_is_refused_for_a_provider_key" {
  command = plan

  variables {
    provider_key_secret_arns = {
      OPENROUTER_API_KEY = "arn:aws:secretsmanager:us-west-2:123456789012:secret:openrouter-key-MnOpQr"
    }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_secret_in_another_region_is_refused_for_the_agent_token" {
  command = plan

  variables {
    agent_github_token_secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:agent-readonly-StUvWx"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_provider_key_that_is_not_an_arn_is_refused" {
  command = plan

  variables {
    provider_key_secret_arns = { OPENROUTER_API_KEY = "sk-or-the-key-itself" }
  }

  expect_failures = [var.provider_key_secret_arns]
}

run "a_provider_key_may_not_replace_a_variable_the_module_sets" {
  command = plan

  variables {
    provider_key_secret_arns = {
      SRE_API_KEY        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:other-AbCdEf"
      OPENROUTER_API_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr"
    }
  }

  expect_failures = [var.provider_key_secret_arns]
}

run "a_provider_key_name_that_is_not_an_environment_variable_is_refused" {
  command = plan

  variables {
    provider_key_secret_arns = { "open router" = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr" }
  }

  expect_failures = [var.provider_key_secret_arns]
}

run "no_provider_key_at_all_is_refused" {
  command = plan

  variables {
    provider_key_secret_arns = {}
  }

  expect_failures = [var.provider_key_secret_arns]
}

run "the_model_provider_must_have_its_key" {
  command = plan

  variables {
    sre_model = "anthropic/claude-sonnet-4-5"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "the_model_provider_with_its_key_is_accepted" {
  command = apply

  variables {
    sre_model = "anthropic/claude-sonnet-4-5"
    provider_key_secret_arns = {
      ANTHROPIC_API_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:anthropic-key-YzAbCd"
    }
  }

  assert {
    condition     = contains([for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.name], "ANTHROPIC_API_KEY")
    error_message = "the key the model's provider reads"
  }
}

run "a_provider_the_package_does_not_map_is_not_refused" {
  command = apply

  variables {
    sre_model = "someprovider/some-model"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].image == var.image
    error_message = "opencode may know a provider the package's table does not; the module cannot judge it"
  }
}
