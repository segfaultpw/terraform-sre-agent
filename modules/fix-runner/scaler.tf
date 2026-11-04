/**
 * The scaler: a Lambda function in your account that sets the service's desired count from SRE
 * Agent's demand, so the fleet costs nothing while there is no work. Everything here exists only
 * when var.scaling is set. The function is scaler/index.mjs, the only code the module ships.
 *
 *   - Every minute it asks GET <sre_agent_url>/api/fix_runner/demand, with the API key in
 *     api_key_secret_arn, how many requests are waiting for a runner and how many are being worked.
 *     The answer is counts only, never a request's content.
 *   - It sets the service's desired count and nothing else; it never stops a task. A task that holds
 *     a request holds ECS task protection, which a scale-in cannot override.
 *   - Its role can describe and update this one service, read this one secret, read and write one
 *     parameter (the idle clock) and write its own logs.
 */

locals {
  scaler_name = "${var.name_prefix}-scaler"
}

data "archive_file" "scaler" {
  count = local.scaled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/scaler/index.mjs"
  output_path = "${path.module}/.build/scaler.zip"
}

resource "aws_cloudwatch_log_group" "scaler" {
  count = local.scaled ? 1 : 0

  name              = "/aws/lambda/${local.scaler_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = local.tags
}

# When the service was first seen idle, in epoch milliseconds, 0 for not idle. The scaler owns the
# value, so Terraform creates it and never resets it.
resource "aws_ssm_parameter" "scaler_idle_since" {
  count = local.scaled ? 1 : 0

  name  = "/${var.name_prefix}/scaler/idle-since"
  type  = "String"
  value = "0"

  tags = local.tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_iam_role" "scaler" {
  count = local.scaled ? 1 : 0

  name = local.scaler_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "lambda.amazonaws.com" }
      },
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "scaler" {
  count = local.scaled ? 1 : 0

  name = "scale-the-fix-runner-service"
  role = aws_iam_role.scaler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "WriteItsOwnLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.scaler[0].arn}:*"
        },
        {
          Sid      = "ReadTheApiKey"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = var.api_key_secret_arn
        },
        {
          Sid      = "ScaleThisServiceOnly"
          Effect   = "Allow"
          Action   = ["ecs:DescribeServices", "ecs:UpdateService"]
          Resource = local.service_arn
        },
        {
          Sid      = "KeepTheIdleClock"
          Effect   = "Allow"
          Action   = ["ssm:GetParameter", "ssm:PutParameter"]
          Resource = aws_ssm_parameter.scaler_idle_since[0].arn
        },
      ],
      var.secrets_kms_key_arn == null ? [] : [
        {
          Sid      = "DecryptTheApiKey"
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = var.secrets_kms_key_arn
          Condition = {
            StringEquals = {
              "kms:ViaService"                  = "secretsmanager.${local.region}.amazonaws.com"
              "kms:EncryptionContext:SecretARN" = var.api_key_secret_arn
            }
          }
        },
      ],
    )
  })
}

resource "aws_lambda_function" "scaler" {
  count = local.scaled ? 1 : 0

  function_name    = local.scaler_name
  description      = "Sets the fix runner service's desired count from SRE Agent's demand"
  role             = aws_iam_role.scaler[0].arn
  runtime          = "nodejs24.x"
  handler          = "index.handler"
  filename         = data.archive_file.scaler[0].output_path
  source_code_hash = data.archive_file.scaler[0].output_base64sha256
  timeout          = 60
  memory_size      = 128

  environment {
    variables = {
      SRE_AGENT_URL      = var.sre_agent_url
      API_KEY_SECRET_ARN = var.api_key_secret_arn
      CLUSTER_ARN        = local.cluster_arn
      SERVICE_NAME       = local.scaled_service_name
      IDLE_PARAMETER     = aws_ssm_parameter.scaler_idle_since[0].name
      MIN_RUNNERS        = tostring(var.scaling.min_runners)
      MAX_RUNNERS        = tostring(var.scaling.max_runners)
      CONCURRENCY        = tostring(var.concurrency)
      IDLE_MINUTES       = tostring(var.scaling.idle_minutes)
    }
  }

  tags = local.tags

  depends_on = [aws_cloudwatch_log_group.scaler, aws_iam_role_policy.scaler]
}

# The next scheduled run, a minute later, is the retry.
resource "aws_lambda_function_event_invoke_config" "scaler" {
  count = local.scaled ? 1 : 0

  function_name          = aws_lambda_function.scaler[0].function_name
  maximum_retry_attempts = 0
}

resource "aws_cloudwatch_event_rule" "scaler" {
  count = local.scaled ? 1 : 0

  name                = local.scaler_name
  description         = "Runs the fix runner scaler once a minute"
  schedule_expression = "rate(1 minute)"

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "scaler" {
  count = local.scaled ? 1 : 0

  rule = aws_cloudwatch_event_rule.scaler[0].name
  arn  = aws_lambda_function.scaler[0].arn
}

resource "aws_lambda_permission" "scaler" {
  count = local.scaled ? 1 : 0

  statement_id  = "AllowEventBridgeScale"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scaler[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.scaler[0].arn
}

# The function raises when SRE Agent cannot be reached or refuses the key, when ECS refuses to
# change the service (a task quota, a subnet, the image), and, after it has scaled out, when its
# SSM idle-clock parameter cannot be read or written, so a scaler that cannot start tasks shows
# here. Nothing else changes meanwhile: a request waits under the usual rules.
resource "aws_cloudwatch_metric_alarm" "scaler_errors" {
  count = local.scaled ? 1 : 0

  alarm_name          = "${local.scaler_name}-errors"
  alarm_description   = "The fix runner scaler has failed for 15 minutes running: SRE Agent cannot be reached or refuses the API key, the API key secret is unreadable or malformed, ECS refuses to change the service, or the SSM parameter that holds the idle clock cannot be read or written (the last still scales out but never scales in). Read the scaler log group; requests wait under the usual rules while it cannot scale."
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
    FunctionName = aws_lambda_function.scaler[0].function_name
  }

  tags = local.tags
}
