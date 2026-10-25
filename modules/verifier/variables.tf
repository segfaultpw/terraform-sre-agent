variable "name_prefix" {
  type        = string
  description = "Prefix of every resource this module creates."
  default     = "sre-agent-verifier"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits and hyphens, 2 to 31 characters, starting with a letter."
  }
}

variable "sre_agent_url" {
  type        = string
  description = <<-EOT
    The origin of your SRE Agent, with no path (https://...). It is the address shown under
    "What your own verifier needs" in Integrations. The poller calls
    <sre_agent_url>/api/verifier/queue and nothing else; the platform never calls the poller.
  EOT

  validation {
    condition     = can(regex("^https://[^/]+$", var.sre_agent_url))
    error_message = "sre_agent_url must be an https origin with no path, such as https://sre.example.com."
  }
}

variable "api_key_secret_arn" {
  type        = string
  description = <<-EOT
    The full ARN of a Secrets Manager secret, with the six-character suffix Secrets Manager adds
    (arn:aws:secretsmanager:<region>:<account>:secret:<name>-AbCdEf), in the Region this module
    deploys to. Its value is the plain SRE Agent organization API key that carries the single
    scope verifier:poll (Settings, API Keys), not a key/value JSON secret, which the platform
    would refuse as unauthorized. Create the secret yourself, so the key never enters Terraform
    state. The poller reads it at run time. A partial ARN (no suffix) would match nothing in IAM
    and every poll would fail with AccessDenied, so it is refused.
  EOT

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+-[A-Za-z0-9]{6}$", var.api_key_secret_arn))
    error_message = "api_key_secret_arn must be the full Secrets Manager secret ARN, including the six-character suffix (arn:aws:secretsmanager:<region>:<account>:secret:<name>-AbCdEf)."
  }
}

variable "api_key_kms_key_arn" {
  type        = string
  description = <<-EOT
    The ARN of the customer-managed KMS key that encrypts the secret, when it is not the
    account's default Secrets Manager key (a key ARN, not an alias). The poller is then also
    allowed kms:Decrypt on that key, only through Secrets Manager and only for the one secret.
  EOT
  default     = null

  validation {
    condition     = var.api_key_kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.api_key_kms_key_arn))
    error_message = "api_key_kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>), not an alias or a key id."
  }
}

variable "log_kms_key_arn" {
  type        = string
  description = <<-EOT
    A customer-managed KMS key that encrypts both log groups, for a policy that requires one:
    test output from your repositories lands in the task log group. Null uses CloudWatch Logs'
    default encryption. The key policy must let the CloudWatch Logs service of this Region
    (logs.<region>.amazonaws.com) use it: kms:Encrypt*, kms:Decrypt*, kms:ReEncrypt*,
    kms:GenerateDataKey* and kms:Describe*, with the kms:EncryptionContext:aws:logs:arn
    condition AWS documents for log groups.
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
    ARNs of private ECR repositories the images are pulled from, when you mirror them there. The
    execution role may then pull from exactly those repositories (and get a login token, which
    AWS allows only on every resource). Empty (the default) gives it no ECR permission, which is
    right for the default images on ghcr.io. Mirror with the multi-arch index preserved (for
    example `skopeo copy --all` or `crane copy`), so the digest the poller reports is unchanged.
  EOT
  default     = []

  validation {
    condition     = alltrue([for arn in var.ecr_repository_arns : can(regex("^arn:aws[a-z-]*:ecr:[a-z0-9-]+:[0-9]{12}:repository/.+$", arn))])
    error_message = "Every ecr_repository_arns entry must be an ECR repository ARN (arn:aws:ecr:<region>:<account>:repository/<name>)."
  }
}

variable "images" {
  type        = map(string)
  description = <<-EOT
    The verifier image to run for each runtime, pinned by digest: runtime (elixir, node, python,
    go, java, php) to a reference like ghcr.io/segfaultpw/sre-agent-verifier-node@sha256:<digest>.
    List only the runtimes your repositories use. The poller reports each digest on every poll
    and SRE Agent hands work only to digests it published; an image it does not recognise, or
    one that is too old, is refused (HTTP 426 to the poller) with a message that names the
    image to move to. That repeats every poll until you change the digest and apply, and every
    pull request opens unverified meanwhile. The Integrations card shows what SRE Agent accepts.
  EOT

  validation {
    condition     = length(var.images) > 0
    error_message = "images needs at least one runtime."
  }

  validation {
    condition     = alltrue([for runtime in keys(var.images) : contains(["elixir", "node", "python", "go", "java", "php"], runtime)])
    error_message = "images keys must be runtimes SRE Agent verifies: elixir, node, python, go, java or php."
  }

  validation {
    condition     = alltrue([for image in values(var.images) : can(regex("^[^@[:space:]]+@sha256:[0-9a-f]{64}$", image))])
    error_message = "Every image must be pinned by digest (name@sha256:<64 hex>). A tag can move, and the platform judges the digest."
  }
}

variable "cpu_architecture" {
  type        = string
  description = "X86_64 or ARM64. The published images are multi-architecture; ARM64 is cheaper on Fargate."
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones for the private subnets the tasks run in, one to three. Defaults to the first two of the Region."
  default     = null

  # The VPC is split into four blocks (cidrsubnet with 2 new bits): one public subnet for the
  # NAT gateway and up to three private ones.
  validation {
    condition     = var.availability_zones == null ? true : (length(var.availability_zones) >= 1 && length(var.availability_zones) <= 3)
    error_message = "availability_zones must name one to three zones: the VPC holds one public subnet and at most three private ones."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR of the VPC this module creates. It holds one public subnet (the NAT gateway) and one private subnet per zone."
  default     = "10.77.0.0/22"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && try(tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 24, false)
    error_message = "vpc_cidr must be an IPv4 CIDR block with a prefix length from /16 to /24 (the range AWS allows for a VPC, and room for four subnets), such as 10.77.0.0/22."
  }
}

variable "https_proxy" {
  type        = string
  description = <<-EOT
    An HTTPS proxy the tasks' commands use (HTTPS_PROXY and HTTP_PROXY). Null for none. It
    reaches only the commands the verifier runs: the image pull and the log delivery ignore it,
    which is why the tasks' egress is the internet on port 443 and cannot be narrowed to the
    proxy. The security group opens port 443 only, so the proxy must listen on 443. The network
    is yours: SRE Agent's per-repository network setting does not apply to it.
  EOT
  default     = null
}

variable "no_proxy" {
  type        = string
  description = "NO_PROXY for the tasks. Used only when https_proxy is set; ignored otherwise."
  default     = "localhost,127.0.0.1,::1"
}

variable "max_ephemeral_storage_gib" {
  type        = number
  description = "Ephemeral storage the task definitions allow, in GiB (21 to 200). SRE Agent asks for 30, 40 or 60 by plan."
  default     = 60

  validation {
    condition     = var.max_ephemeral_storage_gib >= 21 && var.max_ephemeral_storage_gib <= 200
    error_message = "max_ephemeral_storage_gib must be between 21 and 200."
  }
}

variable "log_retention_days" {
  type        = number
  description = "Retention of the task logs and the poller logs, in days. One of the values CloudWatch Logs offers: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention CloudWatch Logs offers: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  }
}

variable "poll_schedule_expression" {
  type        = string
  description = <<-EOT
    How often the poller asks for work: rate(1 minute) up to rate(5 minutes). SRE Agent routes
    nothing to a poller it has not heard from in 5 minutes, so a slower schedule makes every pull
    request open unverified; rate(5 minutes) leaves no slack and is the slowest accepted. A job
    waits up to 15 minutes to be collected, and every poll is also what shows the poller as alive
    in Integrations. A cron expression is not accepted, because its interval cannot be checked.
  EOT
  default     = "rate(1 minute)"

  validation {
    condition     = can(regex("^rate\\((1 minute|[2-5] minutes)\\)$", var.poll_schedule_expression))
    error_message = "poll_schedule_expression must be rate(1 minute) or rate(N minutes) with N from 2 to 5: SRE Agent treats a poller it has not heard from in 5 minutes as gone."
  }
}

variable "poller_reserved_concurrency" {
  type        = number
  description = <<-EOT
    Reserved concurrency for the poller Lambda. Null (the default) reserves nothing, which is
    right for almost everyone: overlapping polls are safe, because SRE Agent hands a job out
    with one conditional write, so the second of two simultaneous polls is given nothing and
    starts nothing. A reservation also fails to apply on an account whose total Lambda
    concurrency is still the new-account limit of 10, because AWS will not let unreserved
    concurrency fall below 10. Set it only to cap what the poller can use in a busy account.
  EOT
  default     = null

  validation {
    condition     = var.poller_reserved_concurrency == null ? true : var.poller_reserved_concurrency >= 1
    error_message = "poller_reserved_concurrency must be null (no reservation) or at least 1; 0 would stop every poll."
  }
}

variable "alarm_actions" {
  type        = list(string)
  description = <<-EOT
    ARNs (an SNS topic, usually) to notify when the poller has failed for 15 minutes running.
    Two alarms use them. One is on Lambda's Errors: the poller raises when the API key is
    refused, the platform is unreachable or its answer cannot be read. The other is on the
    poller's own error log lines (a metric filter on level=error), which also covers what the
    poller logs and then returns from: SRE Agent refusing the poller or an image (HTTP 426,
    which repeats every poll until `images` is changed), a RunTask ECS refused, and a job for
    a runtime with no task definition. These are the failures nobody would otherwise see.
    Empty (the default) builds neither alarm nor the metric filter.
  EOT
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Tags for every resource."
  default     = {}
}
