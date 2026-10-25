/**
 * SRE Agent's self-hosted fix runner on ECS Fargate, in your own account.
 *
 * The runner answers SRE Agent fix requests with opencode on compute you own: it polls SRE Agent
 * over HTTPS for work, clones the repository, lets the agent change it under the package's command
 * fences, runs the protected-paths gate, pushes a branch and opens the pull request. SRE Agent
 * never connects to your account, so there is no listener, no load balancer and no inbound rule.
 *
 *   - One Fargate task, desired count 1, replaced stop-first (maximum 100 percent, minimum healthy
 *     0): the queue is not a lease, and two tasks would do one request twice. ECS starts the
 *     replacement once the old task has left RUNNING, so a short overlap with a task that is still
 *     stopping is possible.
 *   - /workspace is an encrypted EFS volume, so the clones, the agent's home and its notes survive
 *     a replaced task. The access point sets a root directory and who owns it at creation and no
 *     posix_user, because the image starts as root and its runner switches between two accounts.
 *   - The runner mirrors the notes to an S3 bucket you own after every request, and restores them
 *     from it once if the volume is ever empty.
 *   - The task role holds the workspace, the bucket's prefix and what you attach, nothing more. The
 *     agent has none of it unless you set agent_aws_access.
 *
 * The network gives the task outbound 443 to anywhere, NFS to its own volume, and the ports you
 * list in extra_egress_ports. It is your network.
 */

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  count = local.create_network && var.availability_zones == null ? 1 : 0
  state = "available"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = element(split(":", aws_cloudwatch_log_group.this.arn), 3)

  tags = merge({ ManagedBy = "terraform", Purpose = "sre-agent-fix-runner" }, var.tags)

  container_name = "runner"

  # The accounts the image creates (runner/Dockerfile in sre-agent-opencode): the runner is 10001
  # and the agent 10002. The access point creates the root directory owned by the runner and the
  # runner sets every mode inside it when it starts. Fixed ids rather than allocated ones, so a
  # volume keeps working across releases.
  runner_uid = 10001
  runner_gid = 10001

  workspace_path = "/workspace"

  create_network = var.vpc_id == null
  create_cluster = var.cluster_arn == null
  create_bucket  = var.memory_bucket_name == null

  azs = !local.create_network ? [] : (var.availability_zones != null ? var.availability_zones : slice(data.aws_availability_zones.available[0].names, 0, 2))

  vpc_id = local.create_network ? aws_vpc.this[0].id : var.vpc_id
  subnet_ids = local.create_network ? aws_subnet.private[*].id : (
    var.private_subnet_ids == null ? [] : var.private_subnet_ids
  )
  subnet_count = local.create_network ? length(local.azs) : (
    var.private_subnet_ids == null ? 0 : length(var.private_subnet_ids)
  )
  assign_public_ip = local.create_network ? false : var.assign_public_ip

  cluster_arn = local.create_cluster ? aws_ecs_cluster.this[0].arn : var.cluster_arn

  # Named for the account and the Region so it is unique without a random suffix.
  bucket_name = local.create_bucket ? "${var.name_prefix}-memory-${local.account_id}-${local.region}" : var.memory_bucket_name
  bucket_arn  = "arn:${local.partition}:s3:::${local.bucket_name}"

  # The variable each provider reads its key from: scripts/provider_env.sh in the package, which
  # takes it from models.dev. A provider not listed is one opencode may know and this table does
  # not, so the module does not judge it.
  provider_key_variable = {
    "anthropic"    = "ANTHROPIC_API_KEY"
    "openai"       = "OPENAI_API_KEY"
    "google"       = "GOOGLE_GENERATIVE_AI_API_KEY"
    "openrouter"   = "OPENROUTER_API_KEY"
    "xai"          = "XAI_API_KEY"
    "groq"         = "GROQ_API_KEY"
    "mistral"      = "MISTRAL_API_KEY"
    "deepseek"     = "DEEPSEEK_API_KEY"
    "togetherai"   = "TOGETHER_API_KEY"
    "fireworks-ai" = "FIREWORKS_API_KEY"
    "cerebras"     = "CEREBRAS_API_KEY"
    "moonshotai"   = "MOONSHOT_API_KEY"
    "deepinfra"    = "DEEPINFRA_API_KEY"
    "huggingface"  = "HF_TOKEN"
    "zai"          = "ZHIPU_API_KEY"
    "minimax"      = "MINIMAX_API_KEY"
    "nvidia"       = "NVIDIA_API_KEY"
    "opencode"     = "OPENCODE_API_KEY"
    "vercel"       = "AI_GATEWAY_API_KEY"
  }
  expected_provider_key = lookup(local.provider_key_variable, split("/", var.sre_model)[0], null)

  # Fargate's valid pairs: [minimum, maximum, step] in MiB for each CPU size.
  fargate_memory = {
    "1024"  = [2048, 8192, 1024]
    "2048"  = [4096, 16384, 1024]
    "4096"  = [8192, 30720, 1024]
    "8192"  = [16384, 61440, 4096]
    "16384" = [32768, 122880, 8192]
  }
  memory_limits = local.fargate_memory[tostring(var.cpu)]

  secret_env = merge(
    {
      SRE_API_KEY      = var.api_key_secret_arn
      SRE_GITHUB_TOKEN = var.github_token_secret_arn
    },
    var.agent_github_token_secret_arn == null ? {} : { SRE_AGENT_GITHUB_TOKEN = var.agent_github_token_secret_arn },
    var.provider_key_secret_arns,
  )
  secret_arns = sort(distinct(values(local.secret_env)))

  environment = merge(
    var.extra_environment,
    {
      SRE_SERVER_URL     = var.sre_agent_url
      SRE_MODEL          = var.sre_model
      SRE_WORKSPACE      = local.workspace_path
      SRE_MEMORY_BUCKET  = local.bucket_name
      SRE_MEMORY_PREFIX  = var.memory_prefix
      AWS_REGION         = local.region
      AWS_DEFAULT_REGION = local.region
    },
    # Only the exact value 1 opts in, so false is the absence of the variable.
    var.agent_aws_access ? { SRE_AGENT_AWS_ACCESS = "1" } : {},
  )

  # ECS tasks are the principal whose assumption AWS documents the confused-deputy keys for.
  ecs_tasks_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:*" }
        }
      },
    ]
  })
}

## Network: a public subnet for the NAT gateway and a private subnet per zone, unless you bring a VPC.

resource "aws_vpc" "this" {
  count = local.create_network ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name_prefix })
}

resource "aws_internet_gateway" "this" {
  count = local.create_network ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(local.tags, { Name = var.name_prefix })
}

resource "aws_subnet" "public" {
  count = local.create_network ? 1 : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, 0)
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = false

  tags = merge(local.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_subnet" "private" {
  count = local.create_network ? length(local.azs) : 0

  vpc_id            = aws_vpc.this[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, count.index + 1)
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, { Name = "${var.name_prefix}-private-${local.azs[count.index]}" })
}

resource "aws_eip" "nat" {
  count = local.create_network ? 1 : 0

  domain = "vpc"

  tags = merge(local.tags, { Name = "${var.name_prefix}-nat" })
}

resource "aws_nat_gateway" "this" {
  count = local.create_network ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(local.tags, { Name = var.name_prefix })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  count = local.create_network ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route_table_association" "public" {
  count = local.create_network ? 1 : 0

  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  count = local.create_network ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-private" })
}

resource "aws_route_table_association" "private" {
  count = local.create_network ? length(local.azs) : 0

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# No inbound at all. Outbound is HTTPS to anywhere (the image pull, the log delivery, the poll, the
# clones, the model provider and the package registries are hosts this module cannot name), NFS to
# the workspace volume's own group, and whatever extra_egress_ports lists. Fargate ignores a proxy
# for the image pull and the log delivery, so the destination of 443 is not narrowed.
resource "aws_security_group" "tasks" {
  name        = "${var.name_prefix}-tasks"
  description = "Fix runner task: no inbound, outbound HTTPS and the workspace volume"
  vpc_id      = local.vpc_id

  tags = merge(local.tags, { Name = "${var.name_prefix}-tasks" })
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS to anywhere: the image pull, the logs, the poll, the clones and the model provider"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "nfs" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "NFS to the workspace volume only"
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = aws_security_group.efs.id
}

resource "aws_vpc_security_group_egress_rule" "extra" {
  for_each = toset([for port in var.extra_egress_ports : tostring(port)])

  security_group_id = aws_security_group.tasks.id
  description       = "TCP ${each.value} to anywhere, from extra_egress_ports"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "efs" {
  name        = "${var.name_prefix}-efs"
  description = "Fix runner workspace volume: NFS from the runner task only"
  vpc_id      = local.vpc_id

  tags = merge(local.tags, { Name = "${var.name_prefix}-efs" })
}

resource "aws_vpc_security_group_ingress_rule" "efs" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from the runner task"
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = aws_security_group.tasks.id
}

## The workspace volume.

resource "aws_efs_file_system" "this" {
  creation_token   = var.name_prefix
  encrypted        = true
  kms_key_id       = var.efs_kms_key_arn
  performance_mode = "generalPurpose"

  # Clones and installs are bursts of small files; a provisioned or burst-credit volume this
  # small would throttle them.
  throughput_mode = "elastic"

  dynamic "lifecycle_policy" {
    for_each = var.efs_transition_to_ia == "NONE" ? [] : [var.efs_transition_to_ia]

    content {
      transition_to_ia = lifecycle_policy.value
    }
  }

  dynamic "lifecycle_policy" {
    for_each = var.efs_transition_to_ia == "NONE" ? [] : [1]

    content {
      transition_to_primary_storage_class = "AFTER_1_ACCESS"
    }
  }

  tags = merge(local.tags, { Name = var.name_prefix })
}

resource "aws_efs_backup_policy" "this" {
  count = var.enable_backup ? 1 : 0

  file_system_id = aws_efs_file_system.this.id

  backup_policy {
    status = "ENABLED"
  }
}

# The task asks for TLS in its mount; this makes the volume refuse a client that does not. Access
# itself comes from the task role's policy through the access point.
resource "aws_efs_file_system_policy" "this" {
  file_system_id = aws_efs_file_system.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "*"
        Resource  = aws_efs_file_system.this.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_efs_mount_target" "this" {
  count = local.subnet_count

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = local.subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# A root directory and who owns it when it is created, and NO posix_user. The image starts as root
# and its runner runs git and the files in /workspace as one account (uid 10001) and the agent as
# another (uid 10002); a posix_user would make every file on the volume belong to one uid and the
# agent would then be the runner, or neither could write.
resource "aws_efs_access_point" "this" {
  file_system_id = aws_efs_file_system.this.id

  root_directory {
    path = local.workspace_path

    creation_info {
      owner_uid   = local.runner_uid
      owner_gid   = local.runner_gid
      permissions = "0755"
    }
  }

  tags = merge(local.tags, { Name = var.name_prefix })
}

## The memory bucket: created here, or an existing one by name.

resource "aws_s3_bucket" "memory" {
  count = local.create_bucket ? 1 : 0

  bucket        = local.bucket_name
  force_destroy = var.memory_bucket_force_destroy

  tags = local.tags
}

resource "aws_s3_bucket_ownership_controls" "memory" {
  count = local.create_bucket ? 1 : 0

  bucket = aws_s3_bucket.memory[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "memory" {
  count = local.create_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.memory[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "memory" {
  count = local.create_bucket ? 1 : 0

  bucket = aws_s3_bucket.memory[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "memory" {
  count = local.create_bucket ? 1 : 0

  bucket = aws_s3_bucket.memory[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "memory" {
  count = local.create_bucket ? 1 : 0

  bucket = aws_s3_bucket.memory[0].id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.memory_noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.memory]
}

resource "aws_s3_bucket_policy" "memory" {
  count = local.create_bucket ? 1 : 0

  bucket = aws_s3_bucket.memory[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.memory]
}

## Cluster and logs.

resource "aws_ecs_cluster" "this" {
  count = local.create_cluster ? 1 : 0

  name = var.name_prefix

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = local.tags
}

## Roles.

# Pulls the image, reads the secrets into the container's environment and writes its log stream.
# Not available to the agent. Not the AWS managed task execution policy, which is granted on every
# log group and every ECR repository.
resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-execution"
  assume_role_policy = local.ecs_tasks_assume_role_policy

  tags = local.tags
}

resource "aws_iam_role_policy" "execution" {
  name = "run-the-fix-runner-task"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "WriteTheTaskLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = ["${aws_cloudwatch_log_group.this.arn}:*"]
        },
        {
          Sid      = "ReadTheSecrets"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = local.secret_arns
        },
      ],
      var.secrets_kms_key_arn == null ? [] : [
        {
          Sid      = "DecryptTheSecrets"
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = var.secrets_kms_key_arn
          Condition = {
            StringEquals = {
              "kms:ViaService"                  = "secretsmanager.${local.region}.amazonaws.com"
              "kms:EncryptionContext:SecretARN" = local.secret_arns
            }
          }
        },
      ],
      length(var.ecr_repository_arns) == 0 ? [] : [
        {
          # GetAuthorizationToken does not support resource-level permissions.
          Sid      = "GetAnEcrLoginToken"
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"]
          Resource = ["*"]
        },
        {
          Sid      = "PullFromTheNamedRepositories"
          Effect   = "Allow"
          Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
          Resource = var.ecr_repository_arns
        },
      ],
    )
  })
}

# The role the runner process holds, and the agent too when agent_aws_access is true. The
# workspace, the memory prefix, and what extra_policy_arns attaches. It has no log permission:
# the awslogs driver writes with the execution role.
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task"
  assume_role_policy = local.ecs_tasks_assume_role_policy

  tags = local.tags
}

resource "aws_iam_role_policy" "task" {
  name = "workspace-and-memory"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          # ClientRootAccess because the container starts as root and the access point does not
          # change the user; the condition keeps all three to the module's own access point.
          Sid      = "MountTheWorkspace"
          Effect   = "Allow"
          Action   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess"]
          Resource = aws_efs_file_system.this.arn
          Condition = {
            StringEquals = { "elasticfilesystem:AccessPointArn" = aws_efs_access_point.this.arn }
          }
        },
        {
          Sid      = "ListTheMemoryPrefix"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = local.bucket_arn
          Condition = {
            StringLike = { "s3:prefix" = ["${var.memory_prefix}*"] }
          }
        },
        {
          Sid      = "ReadWriteAndDeleteTheMemoryPrefix"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = "${local.bucket_arn}/${var.memory_prefix}*"
        },
      ],
      var.memory_bucket_kms_key_arn == null ? [] : [
        {
          # An existing bucket encrypted with a customer-managed key: every object write needs
          # GenerateDataKey and every read Decrypt. Only when S3 makes the call, so the key cannot
          # be used for anything else the role does.
          Sid      = "UseTheMemoryBucketKey"
          Effect   = "Allow"
          Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
          Resource = var.memory_bucket_kms_key_arn
          Condition = {
            StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" }
          }
        },
      ],
    )
  })

  lifecycle {
    precondition {
      condition     = var.memory_bucket_kms_key_arn == null || var.memory_bucket_name != null
      error_message = "memory_bucket_kms_key_arn is for an existing bucket (memory_bucket_name). The bucket this module creates is encrypted with SSE-S3 and needs no key, and a grant on a key nothing uses is a permission for nothing."
    }

    precondition {
      condition     = var.memory_bucket_kms_key_arn == null || split(":", coalesce(var.memory_bucket_kms_key_arn, "::::"))[3] == local.region
      error_message = "memory_bucket_kms_key_arn is in a different Region than the one this module deploys to. The grant is conditioned on kms:ViaService s3.<this Region>.amazonaws.com, so a key used through another Region's S3 endpoint would never match."
    }
  }
}

# By position, not by value: a for_each over the ARNs needs them at plan time, and the ARN of a
# policy created in the caller's own configuration is not known until it is created. The length of
# the list is (and a repeated ARN is refused by the variable).
resource "aws_iam_role_policy_attachment" "extra" {
  count = length(var.extra_policy_arns)

  role       = aws_iam_role.task.name
  policy_arn = var.extra_policy_arns[count.index]
}

## The task and the service.

resource "aws_ecs_task_definition" "this" {
  family                   = var.name_prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  ephemeral_storage {
    size_in_gib = var.ephemeral_storage_gib
  }

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  volume {
    name = "workspace"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.this.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.this.id
        iam             = "ENABLED"
      }
    }
  }

  # No "user": the image starts as root and its entrypoint resolves the runner and agent accounts
  # and drops to them. No capabilities block: Fargate's default set already holds the six the
  # runner needs to switch accounts (SETUID, SETGID, CHOWN, DAC_OVERRIDE, FOWNER, KILL), and a
  # drop list would be a guess about what a customer's setup script needs. The init process reaps
  # what a killed agent run leaves behind.
  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.image
      essential = true

      # Fargate's longest stop time, a ceiling and not a wait. The runner installs no SIGTERM
      # handler, so on a stop the init process forwards SIGTERM, node exits at once and the
      # container ends in seconds, with a request in flight lost. The ceiling is kept at the
      # maximum so that a runner release which finishes its request on SIGTERM is not cut short
      # by a module that asked for less.
      stopTimeout = 120

      environment = [for name in sort(keys(local.environment)) : { name = name, value = local.environment[name] }]
      secrets     = [for name in sort(keys(local.secret_env)) : { name = name, valueFrom = local.secret_env[name] }]

      mountPoints = [
        {
          sourceVolume  = "workspace"
          containerPath = local.workspace_path
          readOnly      = false
        },
      ]

      linuxParameters = {
        initProcessEnabled = true
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "runner"
        }
      }
    }
  ])

  tags = local.tags

  lifecycle {
    precondition {
      condition = (
        var.memory >= local.memory_limits[0] &&
        var.memory <= local.memory_limits[1] &&
        (var.memory - local.memory_limits[0]) % local.memory_limits[2] == 0
      )
      error_message = "memory ${var.memory} MiB is not a size Fargate offers for ${var.cpu} CPU units: it takes ${local.memory_limits[0]} to ${local.memory_limits[1]} MiB in steps of ${local.memory_limits[2]}."
    }

    precondition {
      condition     = alltrue([for arn in values(local.secret_env) : split(":", arn)[3] == local.region])
      error_message = "A secret is in a different Region than the one this module deploys to. ECS reads each secret through its own Region's endpoint at task start, and the execution role's kms:ViaService condition names this Region, so keep every secret in the deploy Region."
    }

    precondition {
      # A conditional, not ||: Terraform before 1.12 evaluates both sides of ||, and
      # contains() with a null value raises instead of answering.
      condition     = local.expected_provider_key == null ? true : contains(keys(var.provider_key_secret_arns), local.expected_provider_key)
      error_message = "sre_model ${var.sre_model} reads its key from ${coalesce(local.expected_provider_key, "its provider's variable")}, which provider_key_secret_arns does not hold. Add it, or the agent would call the model with no key."
    }
  }
}

resource "aws_ecs_service" "this" {
  name            = var.name_prefix
  cluster         = local.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  launch_type     = "FARGATE"

  # One runner. The queue is not a lease: two tasks sharing one key can both collect the same
  # request and do the work twice, so a deployment stops the old task before it starts the new
  # one. ECS counts only RUNNING and PENDING tasks against the maximum, so the replacement can be
  # provisioned once the old task has left RUNNING, while it is still stopping: a short overlap
  # (the old runner exits on SIGTERM in seconds, a Fargate start takes far longer) is possible, and
  # the module does not claim more than that.
  desired_count                      = 1
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = local.assign_public_ip
  }

  tags = local.tags

  lifecycle {
    precondition {
      condition     = (var.vpc_id == null) == (var.private_subnet_ids == null)
      error_message = "vpc_id and private_subnet_ids go together: set both to run in an existing VPC, or neither to have this module build one."
    }
  }

  depends_on = [
    aws_iam_role_policy.execution,
    aws_iam_role_policy.task,
    aws_iam_role_policy_attachment.extra,
    aws_efs_mount_target.this,
    aws_efs_file_system_policy.this,
    aws_nat_gateway.this,
    aws_route_table_association.private,
  ]
}
