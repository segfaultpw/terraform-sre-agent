# What this module must never loosen: one task that is replaced stop-first (the queue is not a
# lease), no inbound and no load balancer, a task role that holds only the workspace, the memory
# prefix and what the operator attached, an execution role that reads only the named secrets, a
# container that starts as root and keeps the capabilities the runner needs to switch accounts, and
# an image that is not pinned by digest refused before anything is planned. Plans run against
# mocked providers, so no credentials, network or state are used.

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

run "one_task_that_is_replaced_stop_first_with_no_load_balancer" {
  command = apply

  assert {
    condition     = aws_ecs_service.this.desired_count == 1
    error_message = "one runner: the queue is not a lease, two tasks would do one request twice"
  }

  assert {
    condition     = aws_ecs_service.this.deployment_maximum_percent == 100 && aws_ecs_service.this.deployment_minimum_healthy_percent == 0
    error_message = "a deploy stops the old task before it starts the new one, never two at once"
  }

  assert {
    condition     = length(aws_ecs_service.this.load_balancer) == 0
    error_message = "no load balancer: nothing connects to the runner"
  }

  assert {
    condition     = aws_ecs_service.this.launch_type == "FARGATE"
    error_message = "Fargate"
  }

  assert {
    condition     = aws_ecs_service.this.network_configuration[0].assign_public_ip == false
    error_message = "the task gets no public address"
  }

  assert {
    condition     = aws_ecs_service.this.network_configuration[0].security_groups == toset([aws_security_group.tasks.id])
    error_message = "the service uses the module's security group"
  }

  assert {
    condition     = aws_ecs_service.this.deployment_circuit_breaker[0].enable == true && aws_ecs_service.this.deployment_circuit_breaker[0].rollback == true
    error_message = "a deployment that cannot start rolls back to the task that was running, instead of retrying with no one watching"
  }
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

run "the_image_has_no_default" {
  command = plan

  variables {
    image = null
  }

  expect_failures = [var.image]
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

run "a_model_without_a_provider_prefix_is_refused" {
  command = plan

  variables {
    sre_model = "deepseek-v4-pro"
  }

  expect_failures = [var.sre_model]
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

run "extra_environment_refuses_app_connection_string" {
  command = plan

  variables {
    extra_environment = { APP_CONNECTION_STRING = "Server=db;Password=x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_carry_any_secret_looking_name" {
  command = plan

  variables {
    extra_environment = { NPM_REGISTRY_TOKEN = "npm_the_token_itself" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_make_the_runner_exit_after_one_poll" {
  command = plan

  variables {
    extra_environment = { SRE_ONCE = "1" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_name_something_that_is_not_a_variable" {
  command = plan

  variables {
    extra_environment = { "NOT A NAME" = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_path" {
  command = plan

  variables {
    extra_environment = { PATH = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_home" {
  command = plan

  variables {
    extra_environment = { HOME = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_env" {
  command = plan

  variables {
    extra_environment = { ENV = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_bash_env" {
  command = plan

  variables {
    extra_environment = { BASH_ENV = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_node_options" {
  command = plan

  variables {
    extra_environment = { NODE_OPTIONS = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_node_path" {
  command = plan

  variables {
    extra_environment = { NODE_PATH = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_ld_preload" {
  command = plan

  variables {
    extra_environment = { LD_PRELOAD = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_ld_library_path" {
  command = plan

  variables {
    extra_environment = { LD_LIBRARY_PATH = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_git_ssh_command" {
  command = plan

  variables {
    extra_environment = { GIT_SSH_COMMAND = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_git_config_global" {
  command = plan

  variables {
    extra_environment = { GIT_CONFIG_GLOBAL = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_opencode_config" {
  command = plan

  variables {
    extra_environment = { OPENCODE_CONFIG = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_opencode_config_dir" {
  command = plan

  variables {
    extra_environment = { OPENCODE_CONFIG_DIR = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_sre_runner_user" {
  command = plan

  variables {
    extra_environment = { SRE_RUNNER_USER = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_sre_agent_user" {
  command = plan

  variables {
    extra_environment = { SRE_AGENT_USER = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "names_that_only_resemble_a_refused_class_are_accepted" {
  command = apply

  variables {
    extra_environment = {
      PATHS      = "a"
      LDAP_URL   = "ldaps://ldap.example.com"
      GITHUB_ORG = "example"
      OPENCODEX  = "1"
      TZ         = "UTC"
    }
  }

  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment) == 12
    error_message = "the refusal is of PATH, HOME, ENV, BASH_ENV, NODE_OPTIONS, NODE_PATH, LD_*, GIT_*, OPENCODE_* and the two account names, not of names that start the same way"
  }
}

## The network

run "the_security_group_has_no_inbound_and_https_out" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_egress_rule.https.from_port == 443 && aws_vpc_security_group_egress_rule.https.to_port == 443 && aws_vpc_security_group_egress_rule.https.ip_protocol == "tcp"
    error_message = "outbound HTTPS"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.https.cidr_ipv4 == "0.0.0.0/0"
    error_message = "to anywhere: the image pull, the log delivery, the poll, the clones and the model provider are all hosts the module cannot name"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.nfs.from_port == 2049 && aws_vpc_security_group_egress_rule.nfs.to_port == 2049 && aws_vpc_security_group_egress_rule.nfs.ip_protocol == "tcp"
    error_message = "NFS to the workspace volume"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.nfs.referenced_security_group_id == aws_security_group.efs.id && aws_vpc_security_group_egress_rule.nfs.cidr_ipv4 == null
    error_message = "and only to the volume's own security group, not to an address range"
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.extra) == 0
    error_message = "443 and the volume are all by default"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.efs.referenced_security_group_id == aws_security_group.tasks.id && aws_vpc_security_group_ingress_rule.efs.from_port == 2049 && aws_vpc_security_group_ingress_rule.efs.to_port == 2049
    error_message = "the volume accepts NFS from the tasks' group and nothing else; the tasks' group accepts nothing"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.efs.security_group_id == aws_security_group.efs.id
    error_message = "the NFS rule is on the volume's group, so the volume accepts the tasks and the tasks' group accepts nothing"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.https.security_group_id == aws_security_group.tasks.id && aws_vpc_security_group_egress_rule.nfs.security_group_id == aws_security_group.tasks.id
    error_message = "the 443 and NFS rules are on the tasks' group, not on the volume's"
  }

  assert {
    condition     = aws_security_group.tasks.ingress == null || length(aws_security_group.tasks.ingress) == 0
    error_message = "no inline ingress on the tasks' group"
  }

  assert {
    condition     = aws_security_group.tasks.egress == null || length(aws_security_group.tasks.egress) == 0
    error_message = "no inline egress on the tasks' group: every way out is one of the module's rules"
  }

  assert {
    condition     = aws_security_group.efs.ingress == null || length(aws_security_group.efs.ingress) == 0
    error_message = "no inline ingress on the volume's group"
  }

  assert {
    condition     = aws_security_group.efs.egress == null || length(aws_security_group.efs.egress) == 0
    error_message = "the volume's group has no way out"
  }

  assert {
    condition     = length(regexall("(?m)^resource \"aws_vpc_security_group_egress_rule\" ", file("${path.module}/main.tf"))) == 3 && length(regexall("(?m)^resource \"aws_vpc_security_group_ingress_rule\" ", file("${path.module}/main.tf"))) == 1
    error_message = "three egress rules (443, the volume, the operator's ports) and one ingress rule (NFS from the tasks to the volume); another rule is a way in or out nobody reviewed"
  }
}

run "extra_egress_ports_open_those_ports_to_anywhere_and_no_others" {
  command = apply

  variables {
    extra_egress_ports = [22, 80, 5432]
  }

  assert {
    condition     = toset([for r in values(aws_vpc_security_group_egress_rule.extra) : r.from_port]) == toset([22, 80, 5432])
    error_message = "one rule per port"
  }

  assert {
    condition     = alltrue([for r in values(aws_vpc_security_group_egress_rule.extra) : r.from_port == r.to_port && r.ip_protocol == "tcp" && r.cidr_ipv4 == "0.0.0.0/0"])
    error_message = "tcp, one port each, to anywhere"
  }

  assert {
    condition     = alltrue([for r in values(aws_vpc_security_group_egress_rule.extra) : r.security_group_id == aws_security_group.tasks.id])
    error_message = "on the tasks' group, not on the volume's"
  }
}

run "port_443_is_not_an_extra_port" {
  command = plan

  variables {
    extra_egress_ports = [443]
  }

  expect_failures = [var.extra_egress_ports]
}

run "port_2049_is_not_an_extra_port" {
  command = plan

  variables {
    extra_egress_ports = [2049]
  }

  expect_failures = [var.extra_egress_ports]
}

run "a_port_out_of_range_is_refused" {
  command = plan

  variables {
    extra_egress_ports = [70000]
  }

  expect_failures = [var.extra_egress_ports]
}

run "a_repeated_extra_port_is_refused" {
  command = plan

  variables {
    extra_egress_ports = [22, 22]
  }

  expect_failures = [var.extra_egress_ports]
}

run "the_module_builds_a_network_with_a_nat_gateway_by_default" {
  command = apply

  assert {
    condition     = length(aws_vpc.this) == 1 && length(aws_nat_gateway.this) == 1
    error_message = "a VPC and a NAT gateway"
  }

  assert {
    condition     = length(aws_subnet.private) == 2 && length(aws_efs_mount_target.this) == 2
    error_message = "a private subnet and a mount target per zone"
  }

  assert {
    condition     = alltrue([for subnet in aws_subnet.private : subnet.map_public_ip_on_launch == false || subnet.map_public_ip_on_launch == null])
    error_message = "tasks get no public address"
  }
}

run "an_existing_network_is_used_and_nothing_is_built" {
  command = apply

  variables {
    availability_zones = null
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  }

  assert {
    condition     = length(aws_vpc.this) == 0 && length(aws_nat_gateway.this) == 0 && length(aws_subnet.private) == 0 && length(aws_internet_gateway.this) == 0
    error_message = "no network is built"
  }

  assert {
    condition     = aws_security_group.tasks.vpc_id == "vpc-0123456789abcdef0" && aws_security_group.efs.vpc_id == "vpc-0123456789abcdef0"
    error_message = "both groups are in the given VPC"
  }

  assert {
    condition     = aws_ecs_service.this.network_configuration[0].subnets == toset(["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"])
    error_message = "the task runs in the given subnets"
  }

  assert {
    condition     = toset([for m in aws_efs_mount_target.this : m.subnet_id]) == toset(["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"])
    error_message = "a mount target in each"
  }
}

run "a_public_address_is_available_for_an_existing_public_subnet" {
  command = apply

  variables {
    availability_zones = null
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-0123456789abcdef0"]
    assign_public_ip   = true
  }

  assert {
    condition     = aws_ecs_service.this.network_configuration[0].assign_public_ip == true
    error_message = "assign_public_ip reaches the service"
  }
}

run "a_vpc_without_subnets_is_refused" {
  command = plan

  variables {
    vpc_id = "vpc-0123456789abcdef0"
  }

  expect_failures = [aws_ecs_service.this]
}

run "subnets_without_a_vpc_are_refused" {
  command = plan

  variables {
    private_subnet_ids = ["subnet-0123456789abcdef0"]
  }

  expect_failures = [aws_ecs_service.this]
}

run "a_subnet_id_that_is_not_one_is_refused" {
  command = plan

  variables {
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["10.0.0.0/24"]
  }

  expect_failures = [var.private_subnet_ids]
}

run "more_than_three_zones_are_refused" {
  command = plan

  variables {
    availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  }

  expect_failures = [var.availability_zones]
}

run "a_vpc_cidr_without_a_prefix_is_refused" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0"
  }

  expect_failures = [var.vpc_cidr]
}

## The workspace volume

run "the_workspace_is_an_encrypted_volume_mounted_at_workspace_over_tls_with_iam" {
  command = apply

  assert {
    condition     = aws_efs_file_system.this.encrypted == true
    error_message = "encrypted at rest"
  }

  assert {
    condition     = length(aws_ecs_task_definition.this.volume) == 1 && tolist(aws_ecs_task_definition.this.volume)[0].efs_volume_configuration[0].transit_encryption == "ENABLED"
    error_message = "encrypted in transit"
  }

  assert {
    condition     = tolist(aws_ecs_task_definition.this.volume)[0].efs_volume_configuration[0].file_system_id == aws_efs_file_system.this.id
    error_message = "the module's file system"
  }

  assert {
    condition     = tolist(aws_ecs_task_definition.this.volume)[0].efs_volume_configuration[0].authorization_config[0].access_point_id == aws_efs_access_point.this.id && tolist(aws_ecs_task_definition.this.volume)[0].efs_volume_configuration[0].authorization_config[0].iam == "ENABLED"
    error_message = "through the access point, authorised by the task role"
  }

  assert {
    condition = [
      for m in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].mountPoints : m.containerPath if m.sourceVolume == tolist(aws_ecs_task_definition.this.volume)[0].name
    ] == ["/workspace"]
    error_message = "mounted at /workspace, where the image keeps its volume"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].mountPoints[0].readOnly == false
    error_message = "writable"
  }
}

# The image starts as root and its runner switches between two accounts, so the volume must show
# each of them as itself. A posix_user on the access point would force every file to one uid and
# break that split; the access point only fixes the root directory and who owns it when created.
run "the_access_point_has_a_root_directory_and_no_posix_user" {
  command = apply

  assert {
    condition     = length(aws_efs_access_point.this.posix_user) == 0
    error_message = "no posix_user: it would force every file to one uid and break the runner/agent split"
  }

  assert {
    condition     = aws_efs_access_point.this.root_directory[0].path == "/workspace"
    error_message = "a directory of its own, not the root of the file system"
  }

  assert {
    condition     = aws_efs_access_point.this.root_directory[0].creation_info[0].owner_uid == 10001 && aws_efs_access_point.this.root_directory[0].creation_info[0].owner_gid == 10001
    error_message = "created owned by the image's runner account (uid 10001)"
  }

  assert {
    condition     = aws_efs_access_point.this.root_directory[0].creation_info[0].permissions == "0755"
    error_message = "mode 0755 at creation; the runner sets its own modes inside"
  }
}

run "the_volume_is_throttle_free_tiered_and_backed_up_by_default" {
  command = apply

  assert {
    condition     = aws_efs_file_system.this.throughput_mode == "elastic" && aws_efs_file_system.this.performance_mode == "generalPurpose"
    error_message = "elastic throughput: clones and installs are bursts of small files"
  }

  assert {
    condition     = contains([for p in aws_efs_file_system.this.lifecycle_policy : p.transition_to_ia], "AFTER_30_DAYS") && contains([for p in aws_efs_file_system.this.lifecycle_policy : p.transition_to_primary_storage_class], "AFTER_1_ACCESS")
    error_message = "cold files move to infrequent access and come back on the first read"
  }

  assert {
    condition     = aws_efs_backup_policy.this[0].backup_policy[0].status == "ENABLED"
    error_message = "daily backups by default"
  }
}

run "backups_can_be_switched_off" {
  command = apply

  variables {
    enable_backup = false
  }

  assert {
    condition     = length(aws_efs_backup_policy.this) == 0
    error_message = "no backup policy"
  }
}

run "tiering_can_be_switched_off" {
  command = apply

  variables {
    efs_transition_to_ia = "NONE"
  }

  assert {
    condition     = length(aws_efs_file_system.this.lifecycle_policy) == 0
    error_message = "no lifecycle policy"
  }
}

run "an_unknown_tiering_period_is_refused" {
  command = plan

  variables {
    efs_transition_to_ia = "AFTER_45_DAYS"
  }

  expect_failures = [var.efs_transition_to_ia]
}

run "a_customer_managed_key_encrypts_the_volume" {
  command = apply

  variables {
    efs_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = aws_efs_file_system.this.kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "the key reaches the file system"
  }
}

run "the_volume_refuses_clients_that_do_not_use_tls" {
  command = apply

  assert {
    condition = [
      for s in jsondecode(aws_efs_file_system_policy.this.policy).Statement : s.Condition if s.Effect == "Deny"
    ][0] == { Bool = { "aws:SecureTransport" = "false" } }
    error_message = "in-transit encryption is enforced by the file system as well as requested by the task"
  }
}

run "the_volume_accepts_nfs_from_the_tasks_only" {
  command = apply

  assert {
    condition     = length(aws_efs_mount_target.this) == 2 && alltrue([for m in aws_efs_mount_target.this : contains(m.security_groups, aws_security_group.efs.id)])
    error_message = "every mount target is behind the volume's own group"
  }
}

## The memory bucket

run "the_module_creates_a_private_versioned_encrypted_tls_only_bucket" {
  command = apply

  assert {
    condition     = aws_s3_bucket.memory[0].bucket == "sre-agent-fix-runner-memory-123456789012-us-east-1"
    error_message = "named for the account and the Region, so it is unique"
  }

  assert {
    condition     = aws_s3_bucket.memory[0].force_destroy == false
    error_message = "a bucket with notes in it is not destroyed by accident"
  }

  assert {
    condition     = aws_s3_bucket_versioning.memory[0].versioning_configuration[0].status == "Enabled"
    error_message = "versioned: an overwrite or a delete is recoverable"
  }

  assert {
    condition     = tolist(aws_s3_bucket_server_side_encryption_configuration.memory[0].rule)[0].apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "encrypted at rest"
  }

  assert {
    condition = (aws_s3_bucket_public_access_block.memory[0].block_public_acls == true
      && aws_s3_bucket_public_access_block.memory[0].block_public_policy == true
      && aws_s3_bucket_public_access_block.memory[0].ignore_public_acls == true
    && aws_s3_bucket_public_access_block.memory[0].restrict_public_buckets == true)
    error_message = "all four public access blocks"
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.memory[0].rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "no ACLs"
  }

  assert {
    condition     = tolist(aws_s3_bucket_lifecycle_configuration.memory[0].rule)[0].noncurrent_version_expiration[0].noncurrent_days == 90
    error_message = "old versions expire after 90 days by default"
  }

  assert {
    condition     = tolist(aws_s3_bucket_lifecycle_configuration.memory[0].rule)[0].abort_incomplete_multipart_upload[0].days_after_initiation == 7
    error_message = "abandoned uploads do not accumulate"
  }

  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.memory[0].policy).Statement : s.Effect] == ["Deny"]
    error_message = "the bucket policy only denies"
  }

  assert {
    condition     = jsondecode(aws_s3_bucket_policy.memory[0].policy).Statement[0].Condition == { Bool = { "aws:SecureTransport" = "false" } }
    error_message = "TLS only"
  }

  assert {
    condition = toset(jsondecode(aws_s3_bucket_policy.memory[0].policy).Statement[0].Resource) == toset([
      "arn:aws:s3:::sre-agent-fix-runner-memory-123456789012-us-east-1",
      "arn:aws:s3:::sre-agent-fix-runner-memory-123456789012-us-east-1/*",
    ])
    error_message = "on the bucket and its objects"
  }
}

run "the_noncurrent_version_window_and_force_destroy_are_variables" {
  command = apply

  variables {
    memory_noncurrent_version_expiration_days = 14
    memory_bucket_force_destroy               = true
  }

  assert {
    condition     = tolist(aws_s3_bucket_lifecycle_configuration.memory[0].rule)[0].noncurrent_version_expiration[0].noncurrent_days == 14
    error_message = "the window"
  }

  assert {
    condition     = aws_s3_bucket.memory[0].force_destroy == true
    error_message = "force_destroy"
  }
}

run "a_noncurrent_window_below_one_day_is_refused" {
  command = plan

  variables {
    memory_noncurrent_version_expiration_days = 0
  }

  expect_failures = [var.memory_noncurrent_version_expiration_days]
}

run "an_existing_bucket_is_used_and_not_managed" {
  command = apply

  variables {
    memory_bucket_name = "my-existing-notes-bucket"
  }

  assert {
    condition     = length(aws_s3_bucket.memory) == 0 && length(aws_s3_bucket_policy.memory) == 0 && length(aws_s3_bucket_versioning.memory) == 0
    error_message = "nothing is created on, or applied to, a bucket that already exists"
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "SRE_MEMORY_BUCKET=my-existing-notes-bucket")
    error_message = "the runner is told the bucket"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Resource if s.Sid == "ReadWriteAndDeleteTheMemoryPrefix"
    ][0] == "arn:aws:s3:::my-existing-notes-bucket/memory/*"
    error_message = "the grant is on that bucket's prefix"
  }

  assert {
    condition     = output.memory_bucket_name == "my-existing-notes-bucket"
    error_message = "the output names it"
  }
}

run "a_prefix_scopes_both_the_runner_and_the_grant" {
  command = apply

  variables {
    memory_prefix = "team-a/runner/"
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "SRE_MEMORY_PREFIX=team-a/runner/")
    error_message = "the runner is told the prefix"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Resource if s.Sid == "ReadWriteAndDeleteTheMemoryPrefix"
    ][0] == "arn:aws:s3:::sre-agent-fix-runner-memory-123456789012-us-east-1/team-a/runner/*"
    error_message = "and the grant stops at it"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Condition if s.Sid == "ListTheMemoryPrefix"
    ][0] == { StringLike = { "s3:prefix" = ["team-a/runner/*"] } }
    error_message = "so does the list"
  }
}

run "a_prefix_without_a_trailing_slash_is_refused" {
  command = plan

  variables {
    memory_prefix = "memory"
  }

  expect_failures = [var.memory_prefix]
}

run "an_empty_prefix_is_refused_because_it_would_grant_the_whole_bucket" {
  command = plan

  variables {
    memory_prefix = ""
  }

  expect_failures = [var.memory_prefix]
}

run "a_prefix_with_a_wildcard_is_refused" {
  command = plan

  variables {
    memory_prefix = "memory*/"
  }

  expect_failures = [var.memory_prefix]
}

run "a_prefix_that_starts_with_a_slash_is_refused" {
  command = plan

  variables {
    memory_prefix = "/memory/"
  }

  expect_failures = [var.memory_prefix]
}

run "a_prefix_with_a_dot_part_is_refused" {
  command = plan

  variables {
    memory_prefix = "./"
  }

  expect_failures = [var.memory_prefix]
}

run "a_prefix_with_a_dot_dot_part_is_refused" {
  command = plan

  variables {
    memory_prefix = "../"
  }

  expect_failures = [var.memory_prefix]
}

run "a_prefix_with_a_dot_dot_part_in_the_middle_is_refused" {
  command = plan

  variables {
    memory_prefix = "a/../"
  }

  expect_failures = [var.memory_prefix]
}

run "a_prefix_with_a_dot_part_in_the_middle_is_refused" {
  command = plan

  variables {
    memory_prefix = "a/./b/"
  }

  expect_failures = [var.memory_prefix]
}

run "a_prefix_with_an_empty_part_is_refused" {
  command = plan

  variables {
    memory_prefix = "a//b/"
  }

  expect_failures = [var.memory_prefix]
}

run "a_prefix_of_exactly_512_characters_is_accepted" {
  command = apply

  variables {
    memory_prefix = "${substr(join("", [for i in range(60) : "0123456789"]), 0, 511)}/"
  }

  assert {
    condition     = length(var.memory_prefix) == 512
    error_message = "the runner accepts a prefix up to 512 characters, trailing slash included"
  }
}

run "a_prefix_longer_than_512_characters_is_refused" {
  command = plan

  variables {
    memory_prefix = "${substr(join("", [for i in range(60) : "0123456789"]), 0, 512)}/"
  }

  expect_failures = [var.memory_prefix]
}

run "a_prefix_with_dots_inside_a_name_is_accepted" {
  command = apply

  variables {
    memory_prefix = "team.a/..hidden/v1.0/"
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "SRE_MEMORY_PREFIX=team.a/..hidden/v1.0/")
    error_message = "a dot is refused only as a whole part, as the runner refuses it"
  }
}

## An existing bucket encrypted with a customer-managed key

run "a_customer_managed_bucket_key_is_granted_through_s3_and_on_that_key_only" {
  command = apply

  variables {
    memory_bucket_name        = "my-existing-notes-bucket"
    memory_bucket_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = toset([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Action if s.Sid == "UseTheMemoryBucketKey"
    ][0]) == toset(["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"])
    error_message = "the three actions an SSE-KMS object write and read need, nothing else"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Resource if s.Sid == "UseTheMemoryBucketKey"
    ][0] == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "on the one key"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Condition if s.Sid == "UseTheMemoryBucketKey"
    ][0] == { StringEquals = { "kms:ViaService" = "s3.us-east-1.amazonaws.com" } }
    error_message = "only when S3 asks, in this Region"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      !contains(flatten([s.Resource]), "*")
    ])
    error_message = "no statement is on every resource"
  }
}

run "without_a_bucket_key_the_task_role_holds_no_kms_permission" {
  command = apply

  variables {
    memory_bucket_name = "my-existing-notes-bucket"
  }

  assert {
    condition     = !anytrue([for s in jsondecode(aws_iam_role_policy.task.policy).Statement : anytrue([for a in flatten([s.Action]) : startswith(a, "kms:")])])
    error_message = "no key, no grant"
  }
}

run "a_bucket_key_alias_is_refused_because_iam_needs_the_key" {
  command = plan

  variables {
    memory_bucket_name        = "my-existing-notes-bucket"
    memory_bucket_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:alias/notes"
  }

  expect_failures = [var.memory_bucket_kms_key_arn]
}

run "a_bucket_key_is_refused_for_the_bucket_the_module_creates" {
  command = plan

  variables {
    memory_bucket_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  expect_failures = [aws_iam_role_policy.task]
}

run "a_bucket_key_in_another_region_is_refused" {
  command = plan

  variables {
    memory_bucket_name        = "my-existing-notes-bucket"
    memory_bucket_kms_key_arn = "arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  expect_failures = [aws_iam_role_policy.task]
}

run "a_bucket_name_that_is_not_one_is_refused" {
  command = plan

  variables {
    memory_bucket_name = "Not_A_Bucket"
  }

  expect_failures = [var.memory_bucket_name]
}

## Cluster, logs and names

run "the_module_creates_its_cluster_unless_given_one" {
  command = apply

  assert {
    condition     = length(aws_ecs_cluster.this) == 1 && aws_ecs_service.this.cluster == aws_ecs_cluster.this[0].arn
    error_message = "a cluster of its own"
  }
}

run "an_existing_cluster_is_used_by_arn" {
  command = apply

  variables {
    cluster_arn = "arn:aws:ecs:us-east-1:123456789012:cluster/shared"
  }

  assert {
    condition     = length(aws_ecs_cluster.this) == 0 && aws_ecs_service.this.cluster == "arn:aws:ecs:us-east-1:123456789012:cluster/shared"
    error_message = "the service runs in the given cluster"
  }

  assert {
    condition     = output.cluster_arn == "arn:aws:ecs:us-east-1:123456789012:cluster/shared"
    error_message = "the output names it"
  }
}

run "a_cluster_that_is_not_an_arn_is_refused" {
  command = plan

  variables {
    cluster_arn = "shared"
  }

  expect_failures = [var.cluster_arn]
}

run "the_logs_go_to_one_group_with_the_retention_given" {
  command = apply

  variables {
    log_retention_days = 90
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.retention_in_days == 90 && aws_cloudwatch_log_group.this.name == "/ecs/sre-agent-fix-runner"
    error_message = "one group, kept for 90 days"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].logConfiguration.options["awslogs-group"] == "/ecs/sre-agent-fix-runner"
    error_message = "the container writes to it"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "WriteTheTaskLogs"
    ][0] == ["${aws_cloudwatch_log_group.this.arn}:*"]
    error_message = "the execution role writes that group only"
  }
}

run "the_log_group_uses_the_default_encryption_unless_a_key_is_given" {
  command = apply

  assert {
    condition     = aws_cloudwatch_log_group.this.kms_key_id == null
    error_message = "no key, no override"
  }
}

run "a_customer_managed_key_encrypts_the_log_group" {
  command = apply

  variables {
    log_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "the agent's test and build output lands in this group"
  }
}

run "a_retention_cloudwatch_does_not_offer_is_refused" {
  command = plan

  variables {
    log_retention_days = 45
  }

  expect_failures = [var.log_retention_days]
}

run "private_ecr_repositories_are_read_only_when_named" {
  command = apply

  variables {
    ecr_repository_arns = ["arn:aws:ecr:us-east-1:123456789012:repository/fix-runner"]
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if contains(flatten([s.Action]), "ecr:BatchGetImage")
    ][0] == ["arn:aws:ecr:us-east-1:123456789012:repository/fix-runner"]
    error_message = "pull actions on the named repositories only"
  }
}

run "an_ecr_repository_entry_that_is_not_an_arn_is_refused" {
  command = plan

  variables {
    ecr_repository_arns = ["*"]
  }

  expect_failures = [var.ecr_repository_arns]
}

run "a_name_prefix_too_long_for_the_bucket_name_is_refused" {
  command = plan

  variables {
    name_prefix = "a-very-long-name-prefix-that-overflows"
  }

  expect_failures = [var.name_prefix]
}

run "the_origin_is_https_with_no_path" {
  command = plan

  variables {
    sre_agent_url = "http://sre.example.com/app"
  }

  expect_failures = [var.sre_agent_url]
}

run "tags_reach_the_resources" {
  command = apply

  variables {
    tags = { Team = "platform" }
  }

  assert {
    condition     = aws_ecs_service.this.tags.Team == "platform" && aws_ecs_service.this.tags.ManagedBy == "terraform"
    error_message = "the caller's tags and the module's own"
  }
}

run "the_outputs_name_what_an_operator_looks_for" {
  command = apply

  assert {
    condition     = output.service_arn == aws_ecs_service.this.id
    error_message = "the service"
  }

  assert {
    condition     = output.memory_bucket_name == "sre-agent-fix-runner-memory-123456789012-us-east-1"
    error_message = "the bucket"
  }

  assert {
    condition     = output.file_system_id == "fs-0123456789abcdef0"
    error_message = "the file system"
  }

  assert {
    condition     = output.log_group == "/ecs/sre-agent-fix-runner"
    error_message = "the log group"
  }

  assert {
    condition     = output.api_key_scope == "fix_runner:poll"
    error_message = "the one scope the API key must carry"
  }
}
