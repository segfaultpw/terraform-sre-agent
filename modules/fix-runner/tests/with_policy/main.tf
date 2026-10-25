# A caller that creates the policy it attaches in the same configuration: the policy's ARN is
# unknown at plan time, so extra_policy_arns has a known length and unknown elements.

resource "aws_iam_policy" "runner_reads" {
  name = "runner-reads"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents"]
        Resource = "*"
      },
    ]
  })
}

module "runner" {
  source = "../.."

  sre_agent_url           = "https://sre.example.com"
  sre_model               = "openrouter/deepseek/deepseek-v4-pro"
  image                   = "ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  api_key_secret_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-key-AbCdEf"
  github_token_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sre-fix-runner-github-GhIjKl"
  provider_key_secret_arns = {
    OPENROUTER_API_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:openrouter-key-MnOpQr"
  }
  availability_zones = ["us-east-1a", "us-east-1b"]

  extra_policy_arns = [aws_iam_policy.runner_reads.arn]
}
