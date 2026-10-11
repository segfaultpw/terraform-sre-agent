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
    The ARN of a Secrets Manager secret whose value is an SRE Agent organization API key that
    carries the single scope verifier:poll (Settings, API Keys). Create the secret yourself, so
    the key never enters Terraform state. The poller reads it at run time.
  EOT

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+", var.api_key_secret_arn))
    error_message = "api_key_secret_arn must be a Secrets Manager secret ARN."
  }
}

variable "api_key_kms_key_arn" {
  type        = string
  description = "The customer-managed KMS key that encrypts the secret, when it is not the account's default Secrets Manager key. The poller is then also allowed kms:Decrypt on it."
  default     = null
}

variable "images" {
  type        = map(string)
  description = <<-EOT
    The verifier image to run for each runtime, pinned by digest: runtime (elixir, node, python,
    go, java, php) to a reference like ghcr.io/segfaultpw/sre-agent-verifier-node@sha256:<digest>.
    List only the runtimes your repositories use. The poller reports each digest on every poll
    and SRE Agent hands work only to digests it published; an image it does not recognise, or
    one that is too old, is refused with a message that names the image to move to.
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
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 24
    error_message = "vpc_cidr must be a CIDR block of /24 or larger."
  }
}

variable "egress_cidrs" {
  type        = list(string)
  description = <<-EOT
    Where the verifier tasks may open HTTPS connections (port 443, nothing else, no inbound at
    all). The default is the whole internet through the NAT gateway, because a task clones from
    GitHub and installs packages from the registries your repositories use. To restrict it to
    named domains, run an egress proxy or a firewall you operate, put its CIDR here and set
    https_proxy; the verifier image forwards HTTP_PROXY, HTTPS_PROXY and NO_PROXY to the
    commands it runs.
  EOT
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.egress_cidrs) > 0 && alltrue([for cidr in var.egress_cidrs : can(cidrhost(cidr, 0))])
    error_message = "egress_cidrs needs at least one entry, and every entry must be a CIDR block such as 0.0.0.0/0 or 10.9.0.0/28. A task with no egress cannot clone its repository."
  }
}

variable "https_proxy" {
  type        = string
  description = "An HTTPS proxy the tasks and their commands use (HTTPS_PROXY and HTTP_PROXY). Null for none."
  default     = null
}

variable "no_proxy" {
  type        = string
  description = "NO_PROXY for the tasks. Used only when https_proxy is set; ignored otherwise."
  default     = "localhost,127.0.0.1"
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
  description = "Retention of the task logs and the poller logs."
  default     = 30
}

variable "poll_schedule_expression" {
  type        = string
  description = "How often the poller asks for work. A job waits up to 15 minutes to be collected, and every poll is also what shows the poller as alive in Integrations."
  default     = "rate(1 minute)"
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
    The poller raises, so Lambda counts an error, when the API key is refused, the platform
    is unreachable or its answer cannot be read; those are the failures nobody would
    otherwise see. Empty (the default) builds no alarm.
  EOT
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Tags for every resource."
  default     = {}
}
