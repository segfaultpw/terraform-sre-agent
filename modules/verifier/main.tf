/**
 * The customer-run verifier: where SRE Agent's sandbox verification runs, in your own
 * account instead of ours.
 *
 * Before SRE Agent opens a fix as a pull request it can build and test the change in a
 * sandbox. By default that is a sandbox we operate and meter. With this module the same
 * verifier images run on infrastructure you own, so the cost, the quotas and the isolation
 * rules are yours, and the platform never connects to your account:
 *
 *   - a small Lambda (the poller) asks SRE Agent for work once a minute over HTTPS, with an
 *     organization API key that carries the single scope `verifier:poll`;
 *   - for the one job it is handed, it starts the published verifier image as a Fargate task
 *     with the job's single-claim bootstrap URL as the task's only environment variable;
 *   - the task claims that URL once, receives a read-only token for one repository, runs the
 *     repository's own tests before and after the proposed change, reports to a signed URL and
 *     exits. It never receives a credential of ours that can write, and its task role has no
 *     permissions at all.
 *
 * The poller only dispatches, so the 15-minute Lambda limit never applies to a run: a run is
 * a Fargate task. The network gives the tasks outbound HTTPS and nothing inbound; see
 * `egress_cidrs` to narrow where they may connect.
 */

data "aws_availability_zones" "available" {
  count = var.availability_zones == null ? 1 : 0
  state = "available"
}

locals {
  azs = var.availability_zones != null ? var.availability_zones : slice(data.aws_availability_zones.available[0].names, 0, 2)

  tags = merge({ ManagedBy = "terraform", Purpose = "sre-agent-verifier" }, var.tags)

  # Only the variables the runner forwards to the commands it runs (see verifier/contract.md).
  proxy_environment = var.https_proxy == null ? [] : [
    { name = "HTTPS_PROXY", value = var.https_proxy },
    { name = "HTTP_PROXY", value = var.https_proxy },
    { name = "NO_PROXY", value = var.no_proxy },
  ]

  container_name = "verifier"
}

## Network: one public subnet for the NAT gateway, one private subnet per zone for the tasks.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name_prefix })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = var.name_prefix })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, 0)
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = false

  tags = merge(local.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, count.index + 1)
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, { Name = "${var.name_prefix}-private-${local.azs[count.index]}" })
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.tags, { Name = "${var.name_prefix}-nat" })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = merge(local.tags, { Name = var.name_prefix })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-private" })
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# No inbound at all; outbound HTTPS only. Untrusted repository code runs here.
resource "aws_security_group" "tasks" {
  name        = "${var.name_prefix}-tasks"
  description = "Verifier tasks: no inbound, outbound HTTPS only"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name_prefix}-tasks" })
}

resource "aws_vpc_security_group_egress_rule" "https" {
  for_each = toset(var.egress_cidrs)

  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS to ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

## The cluster, the logs and the roles.

resource "aws_ecs_cluster" "this" {
  name = var.name_prefix

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "tasks" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Pulls the image and writes the task's logs. Not available to the code that runs in the task.
resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_partition" "current" {}

# The role the repository's own code runs as. It has NO permissions: no policy is attached to
# it here and none should ever be, so a test, an install script or anything else running in the
# task can call nothing in this account.
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = local.tags
}

## One task definition per runtime, sized for the largest class SRE Agent asks for.

resource "aws_ecs_task_definition" "verifier" {
  for_each = var.images

  family                   = "${var.name_prefix}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "4096"
  memory                   = "8192"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  ephemeral_storage {
    size_in_gib = var.max_ephemeral_storage_gib
  }

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = each.value
      essential = true

      environment = local.proxy_environment

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.tasks.name
          "awslogs-region"        = element(split(":", aws_ecs_cluster.this.arn), 3)
          "awslogs-stream-prefix" = each.key
        }
      }
    }
  ])

  tags = local.tags
}

## The poller.

data "archive_file" "poller" {
  type        = "zip"
  source_file = "${path.module}/lambda/poller.py"
  output_path = "${path.module}/.build/poller.zip"
}

resource "aws_cloudwatch_log_group" "poller" {
  name              = "/aws/lambda/${var.name_prefix}-poller"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "poller" {
  name               = "${var.name_prefix}-poller"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = local.tags
}

# Exactly what a dispatcher needs: write its own logs, read the one secret, start the
# verifier task definitions in the one cluster, and pass the two roles those definitions name.
resource "aws_iam_role_policy" "poller" {
  name = "dispatch-verifier-tasks"
  role = aws_iam_role.poller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "WriteItsOwnLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.poller.arn}:*"
        },
        {
          Sid      = "ReadTheApiKey"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = var.api_key_secret_arn
        },
        {
          Sid      = "StartVerifierTasks"
          Effect   = "Allow"
          Action   = ["ecs:RunTask"]
          Resource = [for definition in aws_ecs_task_definition.verifier : "${definition.arn_without_revision}:*"]
          Condition = {
            ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn }
          }
        },
        {
          Sid      = "PassTheTwoTaskRoles"
          Effect   = "Allow"
          Action   = ["iam:PassRole"]
          Resource = [aws_iam_role.execution.arn, aws_iam_role.task.arn]
          Condition = {
            StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
          }
        },
      ],
      var.api_key_kms_key_arn == null ? [] : [
        {
          Sid      = "DecryptTheApiKey"
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = var.api_key_kms_key_arn
        },
      ]
    )
  })
}

resource "aws_lambda_function" "poller" {
  function_name    = "${var.name_prefix}-poller"
  role             = aws_iam_role.poller.arn
  runtime          = "python3.12"
  handler          = "poller.handler"
  filename         = data.archive_file.poller.output_path
  source_code_hash = data.archive_file.poller.output_base64sha256
  timeout          = 30
  memory_size      = 128

  # No reservation unless asked for. Two polls that overlap are safe: SRE Agent hands a job out
  # with one conditional write, so the second gets nothing and starts nothing (and the API key
  # cache is per container). A reservation of 1 fails to apply on a new AWS account, whose total
  # concurrency of 10 leaves no room to reserve.
  reserved_concurrent_executions = var.poller_reserved_concurrency

  environment {
    variables = {
      SRE_AGENT_URL      = var.sre_agent_url
      API_KEY_SECRET_ARN = var.api_key_secret_arn
      IMAGES             = jsonencode(var.images)
      TASK_DEFINITIONS   = jsonencode({ for runtime, definition in aws_ecs_task_definition.verifier : runtime => definition.family })
      CLUSTER_ARN        = aws_ecs_cluster.this.arn
      SUBNETS            = join(",", aws_subnet.private[*].id)
      SECURITY_GROUPS    = aws_security_group.tasks.id
      CONTAINER_NAME     = local.container_name
    }
  }

  tags = local.tags

  depends_on = [aws_cloudwatch_log_group.poller, aws_iam_role_policy.poller]
}

# EventBridge invokes the poller asynchronously, and Lambda retries a failed asynchronous
# invocation twice by default. The next scheduled poll, a minute later, is the retry; two more
# calls against a platform that is already failing would only add load.
resource "aws_lambda_function_event_invoke_config" "poller" {
  function_name          = aws_lambda_function.poller.function_name
  maximum_retry_attempts = 0
}

# The poller raises when the API key is refused, the platform cannot be reached or its answer
# cannot be read. Without an alarm those would only show in the log group.
resource "aws_cloudwatch_metric_alarm" "poller_errors" {
  count = length(var.alarm_actions) > 0 ? 1 : 0

  alarm_name          = "${var.name_prefix}-poller-errors"
  alarm_description   = "The verifier poller has failed for 15 minutes running: check its log group for the reason (a refused API key, an unreachable SRE Agent or an unreadable answer)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions

  dimensions = {
    FunctionName = aws_lambda_function.poller.function_name
  }

  tags = local.tags
}

resource "aws_cloudwatch_event_rule" "poll" {
  name                = "${var.name_prefix}-poll"
  description         = "Asks SRE Agent for verification work"
  schedule_expression = var.poll_schedule_expression

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "poll" {
  rule = aws_cloudwatch_event_rule.poll.name
  arn  = aws_lambda_function.poller.arn
}

resource "aws_lambda_permission" "poll" {
  statement_id  = "AllowEventBridgePoll"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.poller.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.poll.arn
}
