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
  description = "A runner image pinned by digest, to replace the module's default (the v1.6.0 runner). Null keeps the default."
  default     = null
}

variable "runner_count" {
  type        = number
  description = "How many runner tasks to run on the one workspace volume. One by default; above one the queue leases each job to the task that collects it, and each task works in its own directories while the runner's per-repository locks guard the shared memory. A pool needs the runner image v1.6.0 or newer."
  default     = 1
}

variable "api_key_secret_arn" {
  type        = string
  description = "The full ARN, with its six-character suffix, of the secret that holds the fix_runner:poll API key (the plain key as the value)."
}

variable "github_token_secret_arn" {
  type        = string
  description = "The full ARN of the secret that holds the GitHub token the runner publishes with. Null when you use the GitHub App shape instead."
  default     = null
}

variable "github_app_id" {
  type        = string
  description = "The numeric id of your GitHub App, when the runner authenticates with an App instead of a static token. Null uses the token."
  default     = null
}

variable "github_app_private_key_secret_arn" {
  type        = string
  description = "The full ARN of the secret that holds the App's private key PEM, the .pem file as downloaded from GitHub. Set it together with github_app_id."
  default     = null
}

variable "provider_key_variable" {
  type        = string
  description = "The environment variable your model provider's key is read from, such as OPENROUTER_API_KEY or ANTHROPIC_API_KEY."
}

variable "provider_key_secret_arn" {
  type        = string
  description = "The full ARN of the secret that holds the model provider's API key."
}
