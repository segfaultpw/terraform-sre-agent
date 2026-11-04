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
    condition     = length(aws_ecs_cluster.this) == 1 && aws_ecs_service.this[0].cluster == aws_ecs_cluster.this[0].arn
    error_message = "a cluster of its own"
  }
}

run "an_existing_cluster_is_used_by_arn" {
  command = apply

  variables {
    cluster_arn = "arn:aws:ecs:us-east-1:123456789012:cluster/shared"
  }

  assert {
    condition     = length(aws_ecs_cluster.this) == 0 && aws_ecs_service.this[0].cluster == "arn:aws:ecs:us-east-1:123456789012:cluster/shared"
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
    condition     = aws_ecs_service.this[0].tags.Team == "platform" && aws_ecs_service.this[0].tags.ManagedBy == "terraform"
    error_message = "the caller's tags and the module's own"
  }
}

run "the_outputs_name_what_an_operator_looks_for" {
  command = apply

  assert {
    condition     = output.service_arn == aws_ecs_service.this[0].id
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

## Concurrency and the agent role

run "a_plan_with_none_of_the_new_variables_is_the_shape_it_always_was" {
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
    error_message = "with concurrency, agent_aws_role_arn and scaling unset the environment is exactly the one this module has always set"
  }

  assert {
    condition = toset([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid
    ]) == toset(["MountTheWorkspace", "ListTheMemoryPrefix", "ReadWriteAndDeleteTheMemoryPrefix"])
    error_message = "with agent_aws_role_arn unset the task role gains no statement"
  }

  assert {
    condition     = aws_ecs_service.this[0].desired_count == 1
    error_message = "the fixed fleet keeps its count"
  }
}

run "concurrency_above_one_sets_the_worker_count_and_the_workers_layout" {
  command = apply

  variables {
    concurrency = 2
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
      SRE_CONCURRENCY            = "2"
      SRE_WORKSPACE_PER_INSTANCE = "1"
      SRE_MEMORY_ROOT            = "/workspace/memory"
      AWS_REGION                 = "us-east-1"
      AWS_DEFAULT_REGION         = "us-east-1"
    }
    error_message = "two workers in one task gain exactly SRE_CONCURRENCY and the per-instance layout, and the task stays one service task"
  }

  assert {
    condition     = aws_ecs_service.this[0].desired_count == 1
    error_message = "concurrency is workers inside a task, not more tasks"
  }
}

run "concurrency_of_one_sets_nothing" {
  command = apply

  variables {
    concurrency = 1
  }

  assert {
    condition     = !contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name], "SRE_CONCURRENCY")
    error_message = "at 1 the variable is absent"
  }
}

run "concurrency_eight_is_accepted" {
  command = plan

  variables {
    concurrency = 8
    cpu         = 8192
    memory      = 16384
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.name => e.value }["SRE_CONCURRENCY"] == "8"
    error_message = "the top of the range"
  }
}

run "concurrency_nine_is_refused" {
  command = plan

  variables {
    concurrency = 9
  }

  expect_failures = [var.concurrency]
}
