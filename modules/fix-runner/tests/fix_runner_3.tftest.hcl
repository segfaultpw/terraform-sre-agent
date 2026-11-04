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
run "extra_environment_refuses_app_connection_string" {
  command = plan

  variables {
    extra_environment = { APP_CONNECTION_STRING = "Server=db;Password=x" }
  }

  expect_failures = [var.extra_environment]
}

run "the_documented_runner_variables_are_accepted" {
  command = plan

  variables {
    extra_environment = {
      SRE_RUN_TIMEOUT_SECONDS = "2400"
      SRE_LOG_LEVEL           = "debug"
      SRE_RUNNER_SETUP        = "/opt/setup.sh"
      SRE_SETUP_CHANNEL       = "stable"
      HTTP_PROXY              = "http://proxy.example.internal:3128"
      HTTPS_PROXY             = "http://proxy.example.internal:3128"
      NO_PROXY                = "169.254.170.2,localhost"
      http_proxy              = "http://proxy.example.internal:3128"
      https_proxy             = "http://proxy.example.internal:3128"
      no_proxy                = "169.254.170.2,localhost"
    }
  }

  assert {
    condition     = length(var.extra_environment) == 10
    error_message = "every runner variable the package documents passes the module's refusals"
  }
}

run "a_setup_script_on_the_volume_is_refused" {
  command = plan

  variables {
    extra_environment = { SRE_RUNNER_SETUP = "/workspace/agent-home/setup.sh" }
  }

  expect_failures = [var.extra_environment]
}

run "a_relative_setup_script_is_refused" {
  command = plan

  variables {
    extra_environment = { SRE_RUNNER_SETUP = "setup.sh" }
  }

  expect_failures = [var.extra_environment]
}

run "a_setup_script_that_climbs_out_is_refused" {
  command = plan

  variables {
    extra_environment = { SRE_RUNNER_SETUP = "/opt/../workspace/setup.sh" }
  }

  expect_failures = [var.extra_environment]
}

run "a_provider_key_name_cannot_move_the_boundary" {
  command = plan

  variables {
    provider_key_secret_arns = {
      OPENROUTER_API_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-openrouter-AbCdEf"
      LD_PRELOAD         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-preload-AbCdEf"
    }
  }

  expect_failures = [var.provider_key_secret_arns]
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
    condition     = aws_ecs_service.this[0].network_configuration[0].subnets == toset(["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"])
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
    condition     = aws_ecs_service.this[0].network_configuration[0].assign_public_ip == true
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
