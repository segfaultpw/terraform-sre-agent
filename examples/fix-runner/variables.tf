variable "region" {
  type        = string
  description = "The Region to run the fix runner in."
  default     = "us-east-1"
}

variable "sre_agent_url" {
  type        = string
  description = "Your SRE Agent origin, such as https://sre.example.com."
}

variable "sre_model" {
  type        = string
  description = "The model as provider/model, such as openrouter/deepseek/deepseek-v4-pro."
}

variable "image" {
  type        = string
  description = "The runner image pinned by digest: ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:<digest>."
}

variable "api_key_secret_arn" {
  type        = string
  description = "The full ARN, with its six-character suffix, of the secret that holds the fix_runner:poll API key (the plain key as the value)."
}

variable "github_token_secret_arn" {
  type        = string
  description = "The full ARN of the secret that holds the GitHub token the runner publishes with."
}

variable "provider_key_variable" {
  type        = string
  description = "The environment variable your model provider's key is read from, such as OPENROUTER_API_KEY or ANTHROPIC_API_KEY."
}

variable "provider_key_secret_arn" {
  type        = string
  description = "The full ARN of the secret that holds the model provider's API key."
}
