variable "name_prefix" {
  type        = string
  description = "Prefix of every resource this module creates. At most 24 characters, because the memory bucket's name is this prefix plus the account id and the Region and a bucket name is at most 63."
  default     = "sre-agent-fix-runner"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits and hyphens, 2 to 24 characters, starting with a letter."
  }
}

variable "sre_agent_url" {
  type        = string
  description = <<-EOT
    The origin of your SRE Agent, with no path (https://...). It becomes SRE_SERVER_URL. The runner
    polls <sre_agent_url>/api/fix-runner/queue and nothing else; SRE Agent never calls the runner.
  EOT

  validation {
    condition     = can(regex("^https://[^/]+$", var.sre_agent_url))
    error_message = "sre_agent_url must be an https origin with no path, such as https://sre.example.com."
  }
}

variable "sre_model" {
  type        = string
  description = <<-EOT
    The model the agent uses, as provider/model, for example openrouter/deepseek/deepseek-v4-pro
    or anthropic/claude-sonnet-4-5. It becomes SRE_MODEL. The provider prefix decides which key
    the runner reads (see provider_key_secret_arns).
  EOT

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*/[^/[:space:]][^[:space:]]*$", var.sre_model))
    error_message = "sre_model must be provider/model, for example openrouter/deepseek/deepseek-v4-pro."
  }
}

variable "image" {
  type        = string
  description = <<-EOT
    The runner image, pinned by digest: ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:<64 hex>
    (a name:tag@sha256:... reference is accepted, and the digest decides). A tag is refused because
    it can move under a service that has no one watching it. The default is the sre-agent-opencode
    v2.3.0 runner this module version was built against (a multi-architecture index); null means
    the default. Override it with the digest of another release, from
    https://github.com/segfaultpw/sre-agent-opencode/pkgs/container/sre-agent-opencode-runner, or of
    your own image derived from it (see "Adding what a repository needs" in the README).
  EOT
  default     = "ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:36a476c4ff1fcee7215653c83e9e5098af1b0d790e475dd48842e74b4aa0aeeb"
  nullable    = false

  validation {
    condition     = can(regex("^[^@[:space:]]+@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be pinned by digest (name@sha256:<64 hex>). A tag can move, and this service restarts on its own."
  }
}

variable "cpu_architecture" {
  type        = string
  description = "ARM64 or X86_64. The published image is multi-architecture; ARM64 is cheaper on Fargate."
  default     = "ARM64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "cpu" {
  type        = number
  description = "Fargate CPU units for the task: 1024, 2048, 4096, 8192 or 16384. The agent builds and tests the repositories it fixes in this task."
  default     = 2048

  validation {
    condition     = contains([1024, 2048, 4096, 8192, 16384], var.cpu)
    error_message = "cpu must be 1024, 2048, 4096, 8192 or 16384."
  }
}

variable "memory" {
  type        = number
  description = <<-EOT
    Fargate memory for the task, in MiB, one of the values Fargate offers for the cpu: 1024 CPU
    takes 2048 to 8192 in steps of 1024; 2048 takes 4096 to 16384 in steps of 1024; 4096 takes 8192
    to 30720 in steps of 1024; 8192 takes 16384 to 61440 in steps of 4096; 16384 takes 32768 to
    122880 in steps of 8192. A pair Fargate does not offer is refused at plan time.
  EOT
  default     = 8192
}

variable "ephemeral_storage_gib" {
  type        = number
  description = "Ephemeral storage of the task beside the workspace volume, in GiB (21 to 200). It holds /tmp and the container layers."
  default     = 30

  validation {
    condition     = var.ephemeral_storage_gib >= 21 && var.ephemeral_storage_gib <= 200
    error_message = "ephemeral_storage_gib must be between 21 and 200."
  }
}

variable "runner_count" {
  type        = number
  description = <<-EOT
    How many runner tasks the service runs on the one workspace volume, one by default. The queue
    leases each job to the runner instance that collects it, so two tasks never do one request
    twice; each task works in its own directories (under instances/<its instance id>) while the
    runner's per-repository locks guard the one shared memory tree. Above 1 the task definition
    sets SRE_WORKSPACE_PER_INSTANCE=1 and SRE_MEMORY_ROOT=/workspace/memory. At 1 nothing changes:
    one task, replaced stop-first, and neither pool variable is set. Raise the count through this
    variable, never by editing the service's desired count outside Terraform: such an edit is
    overwritten at the next apply, and the pool variables would not follow it. A pool needs the
    sre-agent-opencode v1.6.0 runner image or newer; an older image sends no instance id, so the
    queue cannot lease, every job is offered to every task, and two tasks can take the same request
    and do it twice.
  EOT
  default     = 1

  validation {
    condition     = var.runner_count == floor(var.runner_count) && var.runner_count >= 1
    error_message = "runner_count must be a whole number of tasks, at least 1."
  }
}

## Secrets

variable "api_key_secret_arn" {
  type        = string
  description = <<-EOT
    The full ARN of a Secrets Manager secret, with the six-character suffix Secrets Manager adds
    (arn:aws:secretsmanager:<region>:<account>:secret:<name>-AbCdEf). Its value is the plain SRE
    Agent organization API key that carries the single scope fix_runner:poll (Settings, API Keys),
    not a key/value JSON secret. It becomes SRE_API_KEY. Create the secret yourself, so the key never
    enters Terraform state, in the Region you deploy to. An ARN without the suffix (a partial ARN)
    would match nothing in IAM; see the README for exactly what is refused.
  EOT

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.api_key_secret_arn))
    error_message = "api_key_secret_arn must be the full Secrets Manager secret ARN, including the six-character suffix (arn:aws:secretsmanager:<region>:<account>:secret:<name>-AbCdEf)."
  }
}

variable "github_token_secret_arn" {
  type        = string
  description = <<-EOT
    The full ARN of a Secrets Manager secret whose value is a GitHub token that may push a branch
    and open a pull request in the repositories this runner is asked to fix (contents and pull
    requests, write). It becomes SRE_GITHUB_TOKEN. The runner publishes with it. Unless
    agent_github_token_secret_arn is set, the agent holds it too, to clone private repositories.
    This is the static-token shape of the module's GitHub authentication; the other shape is a
    GitHub App (github_app_id with github_app_private_key_secret_arn), and exactly one shape is
    allowed: both together and neither at all are refused.
  EOT
  default     = null

  validation {
    condition     = var.github_token_secret_arn == null ? true : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.github_token_secret_arn))
    error_message = "github_token_secret_arn must be the full Secrets Manager secret ARN, including the six-character suffix."
  }
}

variable "github_app_id" {
  type        = string
  description = <<-EOT
    The numeric id of a GitHub App, as a string of digits (the App's About page shows it). With
    github_app_private_key_secret_arn it selects App mode: the task definition sets SRE_GITHUB_APP_ID
    from it and injects the App's private key as SRE_GITHUB_APP_PRIVATE_KEY, and neither
    SRE_GITHUB_TOKEN nor SRE_AGENT_GITHUB_TOKEN exists, because the runner mints a short-lived
    installation token for each request instead (its own to push, the agent's read-only on the
    request's repository). Exactly one GitHub shape is allowed: this pair, or
    github_token_secret_arn with its optional agent counterpart, never both and never neither.
    App mode needs the sre-agent-opencode v1.7.0 runner image or newer.
  EOT
  default     = null

  validation {
    condition     = var.github_app_id == null ? true : can(regex("^[0-9]+$", var.github_app_id))
    error_message = "github_app_id must be the App's numeric id as digits, for example 1234567 (the App's About page shows it)."
  }
}

variable "github_app_private_key_secret_arn" {
  type        = string
  description = <<-EOT
    The full ARN of a Secrets Manager secret whose value is the GitHub App's private key, the PEM
    exactly as the .pem file GitHub lets you download: the newlines are part of it and the runner
    tolerates them, so no base64 or escaping is needed (only surrounding whitespace is trimmed).
    It becomes SRE_GITHUB_APP_PRIVATE_KEY, a secret never printed and never in the agent's
    environment. Set it together with github_app_id; see that variable for the one-shape rule.
  EOT
  default     = null

  validation {
    condition     = var.github_app_private_key_secret_arn == null ? true : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.github_app_private_key_secret_arn))
    error_message = "github_app_private_key_secret_arn must be the full Secrets Manager secret ARN, including the six-character suffix."
  }
}

variable "agent_github_token_secret_arn" {
  type        = string
  description = <<-EOT
    Optional. The full ARN of a secret whose value is a GitHub token for the agent alone, becoming
    SRE_AGENT_GITHUB_TOKEN. A fine-grained token with Contents read-only on the repositories the
    agent needs lets the agent clone and read them but not push; the runner still pushes the branch
    and opens the pull request with the github_token_secret_arn token. Null (the default) omits the
    variable, and the agent then holds the runner's own token, which can push, so only the
    command fence on git push stands between the agent and a push. That default is the owner's
    choice to make and to reverse by setting this. It belongs to the static-token shape: in App
    mode (github_app_id with github_app_private_key_secret_arn) it is refused, because there the
    agent's token is minted per run from the App, read-only on the request's repository.
  EOT
  default     = null

  validation {
    condition     = var.agent_github_token_secret_arn == null ? true : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.agent_github_token_secret_arn))
    error_message = "agent_github_token_secret_arn must be the full Secrets Manager secret ARN, including the six-character suffix."
  }
}

variable "provider_key_secret_arns" {
  type        = map(string)
  description = <<-EOT
    The model provider's key, as environment variable name to the full ARN of the secret that holds
    it. The name is the one the provider uses, which the package maps from the model's prefix:
    anthropic ANTHROPIC_API_KEY, openai OPENAI_API_KEY, google GOOGLE_GENERATIVE_AI_API_KEY,
    openrouter OPENROUTER_API_KEY, xai XAI_API_KEY, groq GROQ_API_KEY, mistral MISTRAL_API_KEY,
    deepseek DEEPSEEK_API_KEY, togetherai TOGETHER_API_KEY, fireworks-ai FIREWORKS_API_KEY, cerebras
    CEREBRAS_API_KEY, moonshotai MOONSHOT_API_KEY, deepinfra DEEPINFRA_API_KEY, huggingface HF_TOKEN,
    zai ZHIPU_API_KEY, minimax MINIMAX_API_KEY, nvidia NVIDIA_API_KEY, opencode OPENCODE_API_KEY,
    vercel AI_GATEWAY_API_KEY. For one of those providers the module refuses a map that lacks the
    key sre_model needs. The agent holds this key too (opencode calls the model with it).
  EOT

  validation {
    condition     = length(var.provider_key_secret_arns) > 0
    error_message = "provider_key_secret_arns needs at least one provider key."
  }

  validation {
    condition = alltrue([
      for name in keys(var.provider_key_secret_arns) :
      can(regex("^[A-Z][A-Z0-9_]*$", name)) && !startswith(name, "SRE_") && !startswith(name, "AWS_")
      && !contains(["PATH", "HOME", "ENV", "BASH_ENV", "NODE_OPTIONS", "NODE_PATH"], name)
      && !startswith(name, "LD_") && !startswith(name, "GIT_") && !startswith(name, "OPENCODE_")
    ])
    error_message = "Every provider_key_secret_arns key must be an upper-case environment variable name that does not start with SRE_ or AWS_ (those are the runner's own and the task's own) and is not one of the names that move the boundary between the runner and the agent (PATH, HOME, ENV, BASH_ENV, NODE_OPTIONS, NODE_PATH, or any LD_*, GIT_* or OPENCODE_* name)."
  }

  validation {
    condition     = alltrue([for arn in values(var.provider_key_secret_arns) : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", arn))])
    error_message = "Every provider_key_secret_arns value must be the full Secrets Manager secret ARN, including the six-character suffix, never the key itself."
  }
}

variable "secrets_kms_key_arn" {
  type        = string
  description = <<-EOT
    The ARN of the customer-managed KMS key that encrypts the secrets, when it is not the account's
    default Secrets Manager key (a key ARN, not an alias). The execution role is then also allowed
    kms:Decrypt on that key, only through Secrets Manager and only for these secrets.
  EOT
  default     = null

  validation {
    condition     = var.secrets_kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.secrets_kms_key_arn))
    error_message = "secrets_kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>), not an alias or a key id."
  }
}

## What the agent can reach

variable "agent_aws_access" {
  type        = bool
  description = <<-EOT
    False (the default): the runner takes the AWS credentials out of the agent's environment and
    the agent runs as an account that cannot read the runner's, so the agent has no AWS access. True
    sets SRE_AGENT_AWS_ACCESS=1, which leaves AWS_* and the ECS container credential variables in
    the agent's environment: the agent then holds the task role, which is the workspace volume, the
    memory bucket's prefix and everything in extra_policy_arns. Turn it on together with
    extra_policy_arns when a diagnosis needs to read the live estate, and give that policy only
    reads. See "What the agent can reach" in the README.
  EOT
  default     = false
}

variable "extra_policy_arns" {
  type        = list(string)
  description = <<-EOT
    Policy ARNs attached to the task role, and nothing else is: this is how an operator grants more
    than the workspace and the memory prefix. They matter to the agent only with agent_aws_access =
    true (the runner itself uses just the workspace and the bucket); without it they are held by
    the runner's process and by a setup script that runs as root, which can use them. An ARN of a
    policy created in the same configuration is fine: only the number of entries must be known at
    plan time.
  EOT
  default     = []

  validation {
    condition     = alltrue([for arn in var.extra_policy_arns : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/.+$", arn))])
    error_message = "Every extra_policy_arns entry must be an IAM policy ARN (arn:aws:iam::aws:policy/<name> or arn:aws:iam::<account>:policy/<name>)."
  }

  validation {
    condition     = length(var.extra_policy_arns) == length(distinct(var.extra_policy_arns))
    error_message = "extra_policy_arns lists a policy twice."
  }
}

variable "extra_environment" {
  type        = map(string)
  description = <<-EOT
    Other runner variables, as plain values, for example SRE_RUNNER_SETUP for a script baked into a
    derived image, SRE_RUN_TIMEOUT_SECONDS or SRE_LOG_LEVEL. They are stored in the task definition
    in clear text, so a value is never a credential: a name that looks like one (it contains KEY,
    TOKEN, SECRET, PASS, AUTH, PRIVATE, CREDENTIAL, DSN, DATABASE_URL or CONNECTION_STRING) is
    refused, and so is any variable this module sets itself or carries as a secret, and SRE_ONCE,
    which would make the runner exit after one poll. SRE_RUNNER_SETUP must be an absolute path in
    the image, never under /workspace, which the agent can write. With a GitHub App
    (github_app_id set) SRE_GITHUB_APP_ID is the module's own as well and is refused (it sets it
    from github_app_id); SRE_GITHUB_APP_PRIVATE_KEY is refused in every mode, because its name is
    credential-shaped. With runner_count above 1,
    SRE_WORKSPACE_PER_INSTANCE and SRE_MEMORY_ROOT are the module's own as well and are refused
    (it sets both for the pool), and so is SRE_RUNNER_INSTANCE, because each task names itself
    by its hostname and one shared identity would make the pool's locks name one instance;
    at 1 they are yours, so a single task can still opt into the split workspace on its own.
    Also refused are the names that move the boundary between the runner and the agent: PATH, HOME,
    ENV, BASH_ENV, NODE_OPTIONS, NODE_PATH, SRE_RUNNER_USER, SRE_AGENT_USER, and any name that
    starts with LD_, GIT_ or OPENCODE_.
  EOT
  default     = {}

  validation {
    condition     = alltrue([for name in keys(var.extra_environment) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", name))])
    error_message = "Every extra_environment key must be an environment variable name: letters, digits and underscores, not starting with a digit."
  }

  validation {
    condition = alltrue([
      for name in keys(var.extra_environment) : !contains([
        "SRE_SERVER_URL", "SRE_MODEL", "SRE_WORKSPACE", "SRE_MEMORY_BUCKET", "SRE_MEMORY_PREFIX",
        "SRE_AGENT_AWS_ACCESS", "SRE_ONCE", "AWS_REGION", "AWS_DEFAULT_REGION",
        "SRE_API_KEY", "SRE_GITHUB_TOKEN", "SRE_AGENT_GITHUB_TOKEN",
      ], name)
    ])
    error_message = "extra_environment cannot set SRE_SERVER_URL, SRE_MODEL, SRE_WORKSPACE, SRE_MEMORY_BUCKET, SRE_MEMORY_PREFIX, SRE_AGENT_AWS_ACCESS, AWS_REGION or AWS_DEFAULT_REGION (this module sets them from its own variables), SRE_API_KEY, SRE_GITHUB_TOKEN or SRE_AGENT_GITHUB_TOKEN (secrets), or SRE_ONCE (the runner would exit after one poll and ECS would restart it in a loop)."
  }

  validation {
    condition = alltrue([
      for name in keys(var.extra_environment) :
      !contains(["PATH", "HOME", "ENV", "BASH_ENV", "NODE_OPTIONS", "NODE_PATH", "SRE_RUNNER_USER", "SRE_AGENT_USER"], name)
      && !startswith(name, "LD_") && !startswith(name, "GIT_") && !startswith(name, "OPENCODE_")
    ])
    error_message = "extra_environment cannot set PATH, HOME, ENV, BASH_ENV, NODE_OPTIONS, NODE_PATH, SRE_RUNNER_USER, SRE_AGENT_USER or any LD_*, GIT_* or OPENCODE_* name: they change which programs the runner and its entrypoint run, who the runner and the agent are, or what the agent is configured with, and so move the boundary between them. Put tools on the image, and use SRE_RUNNER_SETUP for setup."
  }

  validation {
    condition     = !contains(keys(var.extra_environment), "SRE_RUNNER_SETUP") ? true : startswith(var.extra_environment["SRE_RUNNER_SETUP"], "/") && !startswith(var.extra_environment["SRE_RUNNER_SETUP"], "/workspace/") && !can(regex("(^|/)\\.\\.(/|$)", var.extra_environment["SRE_RUNNER_SETUP"]))
    error_message = "SRE_RUNNER_SETUP must be an absolute path in the image, never under /workspace: the volume is writable by the agent, and the entrypoint runs the script as root at the next start."
  }

  validation {
    condition     = alltrue([for name in keys(var.extra_environment) : !can(regex("(KEY|TOKEN|SECRET|PASS|AUTH|PRIVATE|CREDENTIAL|DSN|DATABASE_URL|CONNECTION_STRING)", upper(name)))])
    error_message = "extra_environment is stored in clear text in the task definition, so it cannot carry a name that looks like a credential (KEY, TOKEN, SECRET, PASS, AUTH, PRIVATE, CREDENTIAL, DSN, DATABASE_URL, CONNECTION_STRING). Provider keys go in provider_key_secret_arns."
  }
}

variable "extra_egress_ports" {
  type        = list(number)
  description = <<-EOT
    TCP ports, besides 443, the task may open to anywhere (0.0.0.0/0). Empty (the default) leaves
    port 443 as the only way out, plus NFS to the workspace volume. The agent installs tools and
    clones over HTTPS, but your repositories may need more: 22 for git over ssh, 80 for a package
    mirror, 5432 for a test database. Every port added is a port the agent can use to send anything
    it can read to any host, so add only what a repository's build needs. 443 and 2049 are already
    open and are refused here.
  EOT
  default     = []

  validation {
    condition     = alltrue([for port in var.extra_egress_ports : port >= 1 && port <= 65535 && port == floor(port)])
    error_message = "Every extra_egress_ports entry must be a whole port number from 1 to 65535."
  }

  validation {
    condition     = !contains(var.extra_egress_ports, 443) && !contains(var.extra_egress_ports, 2049)
    error_message = "extra_egress_ports cannot list 443 or 2049: both are already open (HTTPS to anywhere, NFS to the workspace volume only)."
  }

  validation {
    condition     = length(var.extra_egress_ports) == length(distinct(var.extra_egress_ports))
    error_message = "extra_egress_ports lists a port twice."
  }
}

## Memory bucket

variable "memory_bucket_name" {
  type        = string
  description = <<-EOT
    The name of an existing S3 bucket for the runner's memory mirror. Null (the default) creates one
    (versioning, encryption, public access blocked, TLS only). With an existing bucket the module
    creates and changes nothing on it, so it should already be versioned and encrypted; the task
    role is granted list, get, put and delete on memory_prefix only. A bucket encrypted with SSE-S3
    or the AWS managed key aws/s3 needs nothing more; one encrypted with a customer-managed key needs
    memory_bucket_kms_key_arn.
  EOT
  default     = null

  validation {
    condition     = var.memory_bucket_name == null ? true : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.memory_bucket_name))
    error_message = "memory_bucket_name must be an S3 bucket name: 3 to 63 lowercase letters, digits, dots and hyphens."
  }
}

variable "memory_bucket_kms_key_arn" {
  type        = string
  description = <<-EOT
    The ARN of the customer-managed KMS key that encrypts the existing memory_bucket_name (a key
    ARN, not an alias), in the Region you deploy to. The task role is then also allowed
    kms:Encrypt, kms:Decrypt and kms:GenerateDataKey on that key, only when S3 calls it for this
    Region. Without it a bucket encrypted with a customer-managed key refuses every upload and
    restore. Refused without memory_bucket_name: the bucket this module creates uses SSE-S3.
  EOT
  default     = null

  validation {
    condition     = var.memory_bucket_kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.memory_bucket_kms_key_arn))
    error_message = "memory_bucket_kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>), not an alias or a key id."
  }
}

variable "memory_prefix" {
  type        = string
  description = <<-EOT
    The key prefix the runner mirrors its memory under (SRE_MEMORY_PREFIX), ending in one slash. It is
    held to the rule the runner applies at start, or the task would exit and ECS would restart it
    in a loop: at most 512 characters, trailing slash included; every part between slashes is
    letters, digits, dots, underscores and hyphens, and is never empty, "." or "..". The task
    role's access to the bucket stops at this prefix, so it cannot be empty, which would grant the
    whole bucket.
  EOT
  default     = "memory/"

  validation {
    condition     = can(regex("^([A-Za-z0-9._-]+/)+$", var.memory_prefix))
    error_message = "memory_prefix must be one or more path segments of letters, digits, dots, underscores and hyphens, each followed by a slash (for example memory/), with no leading slash, no empty segment and no wildcard."
  }

  validation {
    condition     = alltrue([for part in split("/", var.memory_prefix) : part != "." && part != ".."])
    error_message = "memory_prefix cannot have a part that is . or .. (the runner refuses it at start)."
  }

  validation {
    condition     = length(var.memory_prefix) <= 512
    error_message = "memory_prefix is at most 512 characters, trailing slash included (the runner refuses a longer one at start)."
  }
}

variable "memory_noncurrent_version_expiration_days" {
  type        = number
  description = "Days an overwritten or deleted version of a memory file is kept in the bucket this module creates, before it expires."
  default     = 90

  validation {
    condition     = var.memory_noncurrent_version_expiration_days >= 1 && var.memory_noncurrent_version_expiration_days == floor(var.memory_noncurrent_version_expiration_days)
    error_message = "memory_noncurrent_version_expiration_days must be a whole number of days, at least 1."
  }
}

variable "memory_bucket_force_destroy" {
  type        = bool
  description = "Let terraform destroy delete the bucket this module creates even when it holds objects and versions. False by default: a bucket with notes in it should not vanish with a destroy."
  default     = false
}

## Workspace volume

variable "efs_kms_key_arn" {
  type        = string
  description = "A customer-managed KMS key for the workspace volume. Null uses the AWS managed key for EFS. The key policy must allow EFS to use it."
  default     = null

  validation {
    condition     = var.efs_kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.efs_kms_key_arn))
    error_message = "efs_kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>)."
  }
}

variable "efs_transition_to_ia" {
  type        = string
  description = "When files the agent has not touched move to EFS Infrequent Access, which costs less to keep and a little more to read: AFTER_7_DAYS, AFTER_14_DAYS, AFTER_30_DAYS, AFTER_60_DAYS, AFTER_90_DAYS, or NONE to keep everything in standard storage. A file read once comes back to standard storage."
  default     = "AFTER_30_DAYS"

  validation {
    condition     = contains(["AFTER_7_DAYS", "AFTER_14_DAYS", "AFTER_30_DAYS", "AFTER_60_DAYS", "AFTER_90_DAYS", "NONE"], var.efs_transition_to_ia)
    error_message = "efs_transition_to_ia must be AFTER_7_DAYS, AFTER_14_DAYS, AFTER_30_DAYS, AFTER_60_DAYS, AFTER_90_DAYS or NONE."
  }
}

variable "enable_backup" {
  type        = bool
  description = "Back the workspace volume up daily with AWS Backup's automatic backups (kept 35 days). The volume holds clones that can be fetched again, the agent's home and its memory, which the bucket also mirrors."
  default     = true
}

## Network and cluster

variable "vpc_id" {
  type        = string
  description = <<-EOT
    An existing VPC to run in. Null (the default) builds a small one with a NAT gateway, as the
    verifier module does. With an existing VPC set private_subnet_ids too: the task needs a route
    to the internet from those subnets (a NAT gateway, or a public subnet with assign_public_ip).
  EOT
  default     = null

  validation {
    condition     = var.vpc_id == null ? true : can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id (vpc-...)."
  }
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Subnets of vpc_id for the task and the volume's mount targets, one per zone you want to run in. Null with vpc_id null."
  default     = null

  validation {
    condition     = var.private_subnet_ids == null ? true : (length(var.private_subnet_ids) >= 1 && alltrue([for id in var.private_subnet_ids : can(regex("^subnet-[0-9a-f]+$", id))]))
    error_message = "private_subnet_ids must be one or more subnet ids (subnet-...)."
  }
}

variable "assign_public_ip" {
  type        = bool
  description = "Give the task a public address. Only for an existing VPC whose subnets are public and have no NAT gateway; the security group still admits nothing inbound. Ignored when the module builds the network."
  default     = false
}

variable "availability_zones" {
  type        = list(string)
  description = "Zones for the private subnets of the network this module builds, one to three. Defaults to the first two of the Region. Ignored with an existing VPC."
  default     = null

  validation {
    condition     = var.availability_zones == null ? true : (length(var.availability_zones) >= 1 && length(var.availability_zones) <= 3)
    error_message = "availability_zones must name one to three zones: the VPC holds one public subnet and at most three private ones."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR of the VPC this module builds. It holds one public subnet (the NAT gateway) and one private subnet per zone."
  default     = "10.78.0.0/22"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && try(tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 24, false)
    error_message = "vpc_cidr must be an IPv4 CIDR block with a prefix length from /16 to /24, such as 10.78.0.0/22."
  }
}

variable "cluster_arn" {
  type        = string
  description = "The ARN of an existing ECS cluster to run the service in. Null (the default) creates a cluster of its own."
  default     = null

  validation {
    condition     = var.cluster_arn == null ? true : can(regex("^arn:aws[a-z-]*:ecs:[a-z0-9-]+:[0-9]{12}:cluster/.+$", var.cluster_arn))
    error_message = "cluster_arn must be an ECS cluster ARN (arn:aws:ecs:<region>:<account>:cluster/<name>)."
  }
}

## Logs, images and tags

variable "log_retention_days" {
  type        = number
  description = "Retention of the runner's logs, in days. One of the values CloudWatch Logs offers: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention CloudWatch Logs offers: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  }
}

variable "log_kms_key_arn" {
  type        = string
  description = <<-EOT
    A customer-managed KMS key that encrypts the log group, for a policy that requires one: what the
    agent builds and tests lands in it. Null uses CloudWatch Logs' default encryption. The key policy
    must let the CloudWatch Logs service of this Region (logs.<region>.amazonaws.com) use it.
  EOT
  default     = null

  validation {
    condition     = var.log_kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.log_kms_key_arn))
    error_message = "log_kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>)."
  }
}

variable "ecr_repository_arns" {
  type        = list(string)
  description = <<-EOT
    ARNs of private ECR repositories the image is pulled from, when you mirror or derive it there.
    The execution role may then pull from exactly those repositories (and get a login token, which
    AWS allows only on every resource). Empty (the default) gives it no ECR permission, which is right
    for the image on ghcr.io. Keep the multi-arch index when you mirror, so the digest is unchanged.
  EOT
  default     = []

  validation {
    condition     = alltrue([for arn in var.ecr_repository_arns : can(regex("^arn:aws[a-z-]*:ecr:[a-z0-9-]+:[0-9]{12}:repository/.+$", arn))])
    error_message = "Every ecr_repository_arns entry must be an ECR repository ARN (arn:aws:ecr:<region>:<account>:repository/<name>)."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags for every resource."
  default     = {}
}
