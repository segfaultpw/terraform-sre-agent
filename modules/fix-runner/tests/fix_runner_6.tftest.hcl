# The second model: model_fallback becomes SRE_MODEL_FALLBACK (plain, a model name is not a secret)
# and SRE_MODEL_FALLBACK_KEY (a container secret the execution role may read, never plain
# environment); an unmapped prefix and the same model with the same key are refused at plan time;
# OPENCODE_API_KEY is admitted by its exact name and no other OPENCODE_ or AWS_ name is. Plans run
# against mocked providers, so no credentials, network or state are used.

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

run "no_second_model_by_default" {
  command = apply

  assert {
    condition     = !contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name], "SRE_MODEL_FALLBACK")
    error_message = "without model_fallback there is no SRE_MODEL_FALLBACK"
  }

  assert {
    condition     = !contains([for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.name], "SRE_MODEL_FALLBACK_KEY")
    error_message = "without model_fallback there is no SRE_MODEL_FALLBACK_KEY"
  }

  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets) == 3
    error_message = "the secrets are the API key, the GitHub token and the provider key, as before"
  }

  assert {
    condition     = length(flatten([for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "ReadTheSecrets"])) == 3
    error_message = "the execution role reads exactly the three secrets it read before"
  }
}

run "a_second_model_is_a_variable_and_a_secret" {
  command = apply

  variables {
    model_fallback = {
      model          = "openai/gpt-5"
      key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openai-key-StUvWx"
    }
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_MODEL_FALLBACK"] == "openai/gpt-5"
    error_message = "the model is plain environment"
  }

  assert {
    condition     = { for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.name => s.valueFrom }["SRE_MODEL_FALLBACK_KEY"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:openai-key-StUvWx"
    error_message = "the key is a container secret whose value comes from the ARN"
  }

  assert {
    condition     = !contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name], "SRE_MODEL_FALLBACK_KEY")
    error_message = "the key is never plain environment"
  }

  assert {
    condition     = !strcontains(aws_ecs_task_definition.this.container_definitions, "key_secret_arn") && length(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets) == 4
    error_message = "one secret more, and nothing else about the object leaks into the task definition"
  }

  assert {
    condition     = contains(flatten([for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "ReadTheSecrets"]), "arn:aws:secretsmanager:us-east-1:123456789012:secret:openai-key-StUvWx")
    error_message = "the execution role may read the second key's secret"
  }

  assert {
    condition     = length(flatten([for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource if s.Sid == "ReadTheSecrets"])) == 4
    error_message = "and only that one more"
  }
}

run "a_customer_managed_key_decrypts_the_second_key_too" {
  command = apply

  variables {
    secrets_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    model_fallback = {
      model          = "openai/gpt-5"
      key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openai-key-StUvWx"
    }
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Condition.StringEquals["kms:EncryptionContext:SecretARN"] if s.Sid == "DecryptTheSecrets"
    ][0], "arn:aws:secretsmanager:us-east-1:123456789012:secret:openai-key-StUvWx")
    error_message = "the customer managed key may decrypt the second key's secret"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Condition.StringEquals["kms:EncryptionContext:SecretARN"] if s.Sid == "DecryptTheSecrets"
    ][0]) == 4
    error_message = "and only that one more"
  }
}

run "the_same_model_with_another_key_is_planned" {
  command = apply

  variables {
    model_fallback = {
      model          = "openrouter/deepseek/deepseek-v4-pro"
      key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-second-account-YzAbCd"
    }
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_MODEL_FALLBACK"] == "openrouter/deepseek/deepseek-v4-pro"
    error_message = "the same provider on another account is a second model"
  }
}

run "the_same_key_with_another_model_is_planned" {
  command = apply

  variables {
    model_fallback = {
      model          = "openrouter/anthropic/claude-sonnet-4-5"
      key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr"
    }
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_MODEL_FALLBACK"] == "openrouter/anthropic/claude-sonnet-4-5"
    error_message = "a model that was not found, or a rate limit on one model, does not refuse another model on the same account"
  }
}

run "the_same_model_and_key_is_refused" {
  command = plan

  variables {
    model_fallback = {
      model          = "openrouter/deepseek/deepseek-v4-pro"
      key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr"
    }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "an_unmapped_prefix_is_refused" {
  command = plan

  variables {
    model_fallback = {
      model          = "acmeai/frontier-1"
      key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:acme-key-StUvWx"
    }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "a_malformed_model_is_refused" {
  command = plan

  variables {
    model_fallback = {
      model          = "gpt-5"
      key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openai-key-StUvWx"
    }
  }

  expect_failures = [var.model_fallback]
}

run "a_model_with_a_space_is_refused" {
  command = plan

  variables {
    model_fallback = {
      model          = "openai/gpt 5"
      key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openai-key-StUvWx"
    }
  }

  expect_failures = [var.model_fallback]
}

run "a_malformed_arn_is_refused" {
  command = plan

  variables {
    model_fallback = {
      model          = "openai/gpt-5"
      key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openai-key"
    }
  }

  expect_failures = [var.model_fallback]
}

run "the_key_itself_is_refused" {
  command = plan

  variables {
    model_fallback = {
      model          = "openai/gpt-5"
      key_secret_arn = "sk-not-an-arn"
    }
  }

  expect_failures = [var.model_fallback]
}

run "a_second_key_in_another_region_is_refused" {
  command = plan

  variables {
    model_fallback = {
      model          = "openai/gpt-5"
      key_secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:openai-key-StUvWx"
    }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "opencode_api_key_is_admitted" {
  command = apply

  variables {
    sre_model = "opencode/kimi-k2"
    provider_key_secret_arns = {
      OPENCODE_API_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:opencode-key-AbCdEf"
    }
  }

  assert {
    condition     = { for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.name => s.valueFrom }["OPENCODE_API_KEY"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:opencode-key-AbCdEf"
    error_message = "the opencode provider's key is a container secret by its own name"
  }
}

run "opencode_api_key_as_a_second_model_is_planned" {
  command = apply

  variables {
    model_fallback = {
      model          = "opencode/kimi-k2"
      key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:opencode-key-AbCdEf"
    }
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_MODEL_FALLBACK"] == "opencode/kimi-k2"
    error_message = "opencode is a mapped prefix"
  }
}

run "other_opencode_names_are_still_refused" {
  command = plan

  variables {
    provider_key_secret_arns = {
      OPENROUTER_API_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr"
      OPENCODE_CONFIG    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:opencode-config-AbCdEf"
    }
  }

  expect_failures = [var.provider_key_secret_arns]
}

run "an_opencode_name_that_only_starts_like_the_key_is_refused" {
  command = plan

  variables {
    provider_key_secret_arns = {
      OPENROUTER_API_KEY   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr"
      OPENCODE_API_KEY_TWO = "arn:aws:secretsmanager:us-east-1:123456789012:secret:opencode-two-AbCdEf"
    }
  }

  expect_failures = [var.provider_key_secret_arns]
}

run "aws_names_are_still_refused" {
  command = plan

  variables {
    provider_key_secret_arns = {
      OPENROUTER_API_KEY    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr"
      AWS_SECRET_ACCESS_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:aws-key-AbCdEf"
    }
  }

  expect_failures = [var.provider_key_secret_arns]
}

run "extra_environment_cannot_set_the_second_model" {
  command = plan

  variables {
    extra_environment = { SRE_MODEL_FALLBACK = "openai/gpt-5" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_the_second_key" {
  command = plan

  variables {
    extra_environment = { SRE_MODEL_FALLBACK_KEY = "the-key-itself" }
  }

  expect_failures = [var.extra_environment]
}

run "extra_environment_cannot_set_either_name_beside_a_second_model" {
  command = plan

  variables {
    model_fallback = {
      model          = "openai/gpt-5"
      key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openai-key-StUvWx"
    }
    extra_environment = { SRE_MODEL_FALLBACK = "anthropic/claude-sonnet-4-5" }
  }

  expect_failures = [var.extra_environment]
}
