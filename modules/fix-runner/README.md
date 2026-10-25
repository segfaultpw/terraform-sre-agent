# fix-runner

Runs SRE Agent's **self-hosted fix runner** on ECS Fargate in **your** account. The runner answers
fix requests with [opencode](https://opencode.ai) on compute you own and a model key you own: it
polls SRE Agent over HTTPS for work, clones the repository, lets the agent change it under the
package's command fences, runs the protected-paths gate, pushes a branch and opens the pull
request. The cost of the compute and the tokens is yours; SRE Agent bills nothing for a run on your
runner.

**SRE Agent never connects to your account.** The runner dials out. There is no listener, no load
balancer, no inbound security group rule and no port in the task definition.

This module deploys the runner image published by
[`segfaultpw/sre-agent-opencode`](https://github.com/segfaultpw/sre-agent-opencode)
(`ghcr.io/segfaultpw/sre-agent-opencode-runner`). Its README describes what the runner does, the
variables it reads and what bounds the agent; this README says how this module runs it.

```
SRE Agent  <---- HTTPS long poll (outbound only) ----  Fargate task (desired count 1)
                                                         runner (uid 10001) + agent (uid 10002)
                                                              |                    |
                                                  /workspace (EFS, encrypted)   S3 bucket you own
                                                  clones, agent home, notes     mirror of the notes
```

## Availability

The self-hosted fix runner is a plan feature (`self_hosted_fix_runner`). A runner of an
organization without it is refused by the queue and says so in its log.

## Usage

1. In SRE Agent, **Integrations, Fix runner**: register the runner under a name you will recognise
   in the logs. Then **Settings, API Keys**: create an organization API key whose only scope is
   `fix_runner:poll`. It reaches the job queue and nothing else.
2. Put three values in Secrets Manager, outside Terraform so they never enter state, and without a
   value ever appearing on a command line (shell history and the process list show arguments).
   Paste each value into a file only you can read, create the secret from the file, then delete the
   file. Each value is the plain string, not a key/value JSON secret (the console's default type):

   ```sh
   umask 077
   cat > value.txt        # paste the value, press Enter, then Ctrl-D
   aws secretsmanager create-secret --name sre-fix-runner-key --secret-string file://value.txt
   rm value.txt
   ```

   - the API key from step 1;
   - a GitHub token that may push a branch and open a pull request in the repositories the runner
     fixes (contents and pull requests, write);
   - your model provider's API key.

   Create them in the Region you deploy to. The module needs each secret's **full ARN, with its
   six-character suffix**, which `create-secret` prints and
   `aws secretsmanager describe-secret --secret-id sre-fix-runner-key --query ARN --output text`
   shows again.
3. Apply the module. The image is **required**: there is no default yet, and a tag is refused. Pin
   the digest of the `sre-agent-opencode` release you want (from its package page on GHCR). Use a
   release whose README documents `SRE_MEMORY_BUCKET` and `SRE_MEMORY_PREFIX`; an older image
   ignores them, and the notes then stay on the volume without the bucket mirror.

```hcl
data "aws_secretsmanager_secret" "api_key" { name = "sre-fix-runner-key" }
data "aws_secretsmanager_secret" "github" { name = "sre-fix-runner-github" }
data "aws_secretsmanager_secret" "openrouter" { name = "sre-fix-runner-openrouter" }

module "sre_agent_fix_runner" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/fix-runner?ref=v4.2.0"

  sre_agent_url = "https://sre.example.com"
  sre_model     = "openrouter/deepseek/deepseek-v4-pro"
  image         = "ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:<64 hex digits of the release>"

  api_key_secret_arn      = data.aws_secretsmanager_secret.api_key.arn
  github_token_secret_arn = data.aws_secretsmanager_secret.github.arn
  provider_key_secret_arns = {
    OPENROUTER_API_KEY = data.aws_secretsmanager_secret.openrouter.arn
  }
}
```

   The data sources read the secrets' addresses, never their values.
4. In SRE Agent, set a repository's **Fix runner** to **Self-hosted runner** for requests that name
   that repository. Requests that name no repository go to the runner whenever it is live. The
   Integrations card shows **Polling now** within a minute of the task starting.

## What it builds

| Resource | Notes |
|---|---|
| ECS service, one Fargate task | Desired count 1, maximum percent 100, minimum healthy percent 0, no load balancer, deployment circuit breaker on. ARM64 by default, 2 vCPU and 8 GiB. |
| EFS file system, one access point, a mount target per subnet | Encrypted at rest (your KMS key with `efs_kms_key_arn`), TLS enforced by the file system policy and requested in the mount, elastic throughput, cold files to Infrequent Access, daily AWS Backup (`enable_backup`). Mounted at `/workspace`. |
| S3 bucket (or yours by name) | The memory mirror: versioning, SSE-S3, all four public access blocks, no ACLs, a TLS-only bucket policy, old versions expire after 90 days. |
| `-task` role | The workspace volume (through the one access point), list/get/put/delete on the memory prefix, and exactly the policies in `extra_policy_arns`. |
| `-execution` role | Writes the log stream, reads the named secrets (plus `kms:Decrypt` on your key through Secrets Manager, and pulls from named ECR repositories, when you set them). Not available to the agent. |
| Security groups | The task: **no inbound**; outbound 443 to anywhere, NFS to the volume's group, and `extra_egress_ports`. The volume: NFS from the task's group only. |
| Log group | `/ecs/<name_prefix>`, 30 days by default. |
| VPC, one public subnet, a private subnet per zone, NAT gateway | Built unless you pass `vpc_id` and `private_subnet_ids`. |
| ECS cluster | Built unless you pass `cluster_arn`. |

## One runner, replaced stop-first

The queue is not a lease: two runners sharing one key can both collect the same request and do the
work twice. So the service runs exactly one task and a deployment stops the old task before it
starts the new one (maximum 100 percent, minimum healthy 0). That also means the volume is never
mounted by two writers at once. Do not raise `desired_count` by hand.

A replacement is a gap of about a minute in which the runner is not polling; a request that
arrives meanwhile waits, or after five minutes without a poll runs on SRE Agent's own agent, which
the card says. The task is given the longest stop time Fargate allows (120 seconds). A request the
runner was handling when its task stopped is lost: SRE Agent fails it 45 minutes after it was
queued, and nothing reaches your default branch. Change the image digest (or any other setting that
changes the task definition), apply, and ECS does the replacement; the volume and the bucket keep
the clones and the notes.

The container has no health check because the runner has no port. Its health is SRE Agent's: the
Integrations card says **Polling now**, **Not polling**, **Never polled** or **Switched off**. A
runner that cannot start (a missing value, a missing tool) says why on the first lines of the log
group and exits, and ECS retries; after repeated failures the circuit breaker fails the deployment.

## Persistence and memory

`/workspace` is the EFS volume, so what the runner keeps survives a replaced task:

```
/workspace/repos/<owner>/<repo>/      work trees, reused between requests
/workspace/gitdirs/<owner>/<repo>/    the runner's own git directories (closed to the agent)
/workspace/memory/<owner>/<repo>/     the agent's NOTES.md and scripts/ for that repository
/workspace/memory/_estate/            the same for requests that name no repository
/workspace/agent-home/                the agent's home: mise runtimes, npm -g, pip --user, caches
/workspace/scratch/                   requests that name no repository
```

The first request for a repository pays for the clone and for whatever the agent installs; later
ones reuse both.

**The memory mirror.** After every request the runner copies the changed files under
`/workspace/memory` to `s3://<bucket>/<memory_prefix>` (put and delete). The mirror is one way and
the volume is the source of truth: when `/workspace/memory` is missing or empty (a new or replaced
file system) the runner downloads the prefix once before its first poll, and otherwise never
reads the bucket. Nothing is merged, so an edit made directly in the bucket is overwritten by the
next upload of that file. The bucket is versioned, so an overwrite or a delete is recoverable until
`memory_noncurrent_version_expiration_days` (90 by default) has passed. A failed upload is logged
and reported and never fails a request.

The task role may list, get, put and delete under `memory_prefix` and nothing else in the bucket.
An existing bucket (`memory_bucket_name`) is used as it is: the module creates and changes nothing
on it, so make it versioned and encrypted yourself. Several runners can share one bucket with
different `memory_prefix` values.

**What SRE Agent sees.** Each report lists what the run added, changed or removed in the memory
(paths, kind of change, size and a short summary the agent wrote), shown as inert text. The
contents live only on your volume and in your bucket; SRE Agent never receives them. The memory
never reaches a pull request: it lives outside every checkout and the runner's gate refuses a
staged path under `.sre-agent-memory/`.

## Why the access point has no posix_user

The image starts as **root** inside the container (only the container), and its entrypoint resolves
two accounts from the package's Dockerfile: `runner` (uid 10001), which owns `/workspace` and runs
every git call, and `agent` (uid 10002), which runs opencode and owns only the checkout of the
current request and its home. The split between them is what keeps the agent out of the runner's
environment, the memory directory and other repositories' clones.

An EFS access point with a `posix_user` overrides the user of every NFS request and so makes every
file on the volume belong to one uid. With that, the agent would be the runner (the split gone) or
neither account could write what the other made. So the access point sets only a root directory
(`/workspace` inside the file system) and, for when it creates that directory, an owner
(10001:10001) and mode 0755; the runner sets its own modes inside it when it starts (the workspace
is 0711, `memory/` and the git directories 0700). For the same reason the task definition sets no
`user`.

Two consequences, both deliberate:

- The task role carries `elasticfilesystem:ClientRootAccess` as well as `ClientMount` and
  `ClientWrite`, because the container's root user mounts the volume. All three are conditioned on
  this module's access point, so none of them reaches any other file system or directory.
- The task definition has no `linuxParameters.capabilities` block. Fargate's default set already
  holds the six capabilities the runner needs to switch accounts (`SETUID`, `SETGID`, `CHOWN`,
  `DAC_OVERRIDE`, `FOWNER` and `KILL`), and the module neither adds nor drops any. The only Linux
  parameter it sets is the init process, which reaps what a killed agent run leaves behind. The
  agent itself holds no capability.

## What the agent can reach

Read this before you grant the task role anything. The agent has a shell, and what bounds it is the
machine you put it on, not a list of denied commands.

**What the separate account and the environment scrub stop.** The runner removes its poll key, the
repository token and, unless you set `agent_aws_access`, the `AWS_*` and ECS container credential
variables from the environment it starts the agent in, and the agent runs as a different account
from the runner. So the agent cannot read the runner's process environment (`/proc/<pid>/environ`
refuses another account), the runner's git and `gh` state, the memory directory, another
repository's clone or the runner's git directories; it holds no capability, so it is not root and
cannot install system packages; and it has no AWS credentials unless you opt in. The package's
`tests/uid_split_test.sh` proves the split with real accounts. This module cannot test it for you.

**What they do not stop.**

- **The network.** The task can reach any host on port 443 and on any port you list in
  `extra_egress_ports`. The agent can send what it can read to any of them. The security group
  limits ports, not destinations, because the image pull, the log delivery, the poll, GitHub, the
  model provider and the package registries are hosts the module cannot name.
- **What it holds.** The model provider key stays in the agent's environment (opencode calls the
  model with it), and so does a GitHub token, because your repositories are private and the agent
  clones them as a CI job does. Without `agent_github_token_secret_arn` that token is the runner's
  own, which can push, and only the package's command fence on `git push` stands between the agent
  and a push to any repository that token reaches; the fence is a speed bump, because an
  interpreter (`sh -c`, `python -c`, a script the agent writes) is one command whose contents no
  pattern describes. **Set `agent_github_token_secret_arn` to a fine-grained token with Contents
  read-only** and the token stops the push as well: the agent can clone and read, the runner still
  pushes the branch and opens the pull request. Left unset, the agent holds the runner's token,
  which the owner of the deployment chooses and can reverse by setting it.
- **Files any account may read** in the image, and the repositories' own code and test scripts,
  which run as the agent.
- **A setup script.** If you set `SRE_RUNNER_SETUP` (below) it runs as root, before the first poll,
  with the task role's credentials in its environment (it is not given `SRE_API_KEY` or
  `SRE_GITHUB_TOKEN`). It is yours; keep it short and idempotent.

**`agent_aws_access` and `extra_policy_arns`.** By default (`agent_aws_access = false`) the module
sets nothing and the agent has no AWS access: the runner, not the agent, uses the task role (the
volume and the bucket). Setting `agent_aws_access = true` sets `SRE_AGENT_AWS_ACCESS=1`, which
leaves the credentials in the agent's environment. The agent then holds **everything the task role
holds**: the workspace volume, the memory prefix (versioned, so an overwrite or a delete is
recoverable) and every policy in `extra_policy_arns`. That is how you let a diagnosis read the
live estate: attach a read-only policy of your own, set both, and keep the policy to reads.
`extra_policy_arns` without `agent_aws_access` grants nothing to the agent; only the runner
process and a setup script can use it. Never attach a policy that writes to a place whose loss you
cannot recover.

**Give the runner an account of its own** if your other workloads hold production credentials. A
runner placed in a VPC with routes to them shares their reachability with the agent.

## The network

The task's security group has no inbound rule. Outbound it opens:

| Port | To | Why |
|---|---|---|
| TCP 443 | `0.0.0.0/0` | The image pull, the log delivery, the poll to SRE Agent, `git clone` and the push over HTTPS, the model provider, package registries. Not a variable: on Fargate the image pull and the log delivery ignore a proxy, so a narrower group stops the task before it starts. |
| TCP 2049 | the volume's security group | NFS to `/workspace`. Nothing else. |
| each of `extra_egress_ports` | `0.0.0.0/0` | Your own needs: 22 for git over ssh, 80 for a package mirror, 5432 for a test database. Empty by default. |

DNS is not filtered by security groups. The tasks leave from the NAT gateway's address (output
`nat_public_ip`) when the module builds the network; allow it wherever your source host or package
registry restricts by address. With an existing VPC the subnets need a route to the internet (a NAT
gateway, or public subnets with `assign_public_ip = true`; the task still admits nothing inbound).
If you need named-domain egress, put a transparent firewall in the NAT path of your own network.

## Adding what a repository needs

The image carries a base toolset (a C toolchain, git, `gh`, python with pip and venv, node, the AWS
CLI, `kubectl` and `mise`). Three ways to add more, in the order to try them:

1. **The agent installs it in its own home.** `mise` for language runtimes, `npm -g`, `pip --user`,
   `cargo`, `go install`, `gem`, `mix`. The home is on the volume, so the first request pays and
   the later ones reuse it. This needs nothing from you.
2. **A setup script,** run as root once at container start. Set `SRE_RUNNER_SETUP` through
   `extra_environment` to the path of an executable file that is in the image (bake it into a
   derived image; the runner never fetches a script). It runs on every container start, so keep it
   idempotent and quick (an `apt-get install` of a few packages). The runner does not start if it
   fails.
3. **A derived image.** `FROM ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:...`, install as
   root, leave the `ENTRYPOINT` and `USER` alone, push it to a registry the execution role can pull
   from (for a private ECR repository set `ecr_repository_arns`) and pass its digest as `image`.

```hcl
  image             = "123456789012.dkr.ecr.us-east-1.amazonaws.com/fix-runner@sha256:<64 hex digits>"
  ecr_repository_arns = ["arn:aws:ecr:us-east-1:123456789012:repository/fix-runner"]
  extra_environment = {
    SRE_RUNNER_SETUP = "/opt/setup.sh"
  }
```

`extra_environment` is stored in clear text in the task definition, so it never carries a
credential: a name containing `KEY`, `TOKEN`, `SECRET`, `PASSWORD`, `PASSWD` or `CREDENTIAL` is
refused, and so is any variable this module sets itself or carries as a secret, and `SRE_ONCE`
(the runner would exit after one poll and ECS would restart it in a loop).

## Inputs

| Variable | Default | What it does |
|---|---|---|
| `sre_agent_url` | required | Your SRE Agent origin, an https URL with no path. Becomes `SRE_SERVER_URL`. |
| `sre_model` | required | `provider/model`, for example `openrouter/deepseek/deepseek-v4-pro`. Becomes `SRE_MODEL`. |
| `image` | **required, no default yet** | The runner image pinned by digest. A tag is refused. The default will be the digest of the package release this module version was built against. |
| `api_key_secret_arn` | required | Full ARN of the secret holding the `fix_runner:poll` API key. Becomes `SRE_API_KEY`. |
| `github_token_secret_arn` | required | Full ARN of the secret holding the token the runner publishes with. Becomes `SRE_GITHUB_TOKEN`. |
| `provider_key_secret_arns` | required | Environment variable name to the full ARN of the provider's key secret, for example `OPENROUTER_API_KEY`. For a provider the package maps, the key `sre_model` needs must be present. |
| `agent_github_token_secret_arn` | `null` | A read-only token for the agent alone (`SRE_AGENT_GITHUB_TOKEN`). Null omits it, and the agent holds the runner's token. |
| `secrets_kms_key_arn` | `null` | The customer-managed key behind the secrets, so the execution role may decrypt them through Secrets Manager. |
| `agent_aws_access` | `false` | `true` sets `SRE_AGENT_AWS_ACCESS=1`: the agent holds the task role. |
| `extra_policy_arns` | `[]` | Policies attached to the task role. Nothing else is. |
| `extra_environment` | `{}` | Other runner variables as plain values, for example `SRE_RUNNER_SETUP`. |
| `extra_egress_ports` | `[]` | TCP ports besides 443 opened to anywhere. |
| `cpu_architecture` | `ARM64` | `ARM64` or `X86_64`. |
| `cpu`, `memory` | `2048`, `8192` | Fargate sizing. A pair Fargate does not offer is refused at plan time. |
| `ephemeral_storage_gib` | `30` | Scratch beside the volume, 21 to 200. |
| `memory_bucket_name` | `null` | An existing bucket for the memory mirror. Null creates one. |
| `memory_prefix` | `memory/` | The mirror's prefix, `SRE_MEMORY_PREFIX`; the task role's bucket access stops here. |
| `memory_noncurrent_version_expiration_days` | `90` | How long old versions of a memory file are kept in the bucket the module creates. |
| `memory_bucket_force_destroy` | `false` | Let `terraform destroy` delete a bucket that holds objects. |
| `efs_kms_key_arn` | `null` | A customer-managed key for the volume. |
| `efs_transition_to_ia` | `AFTER_30_DAYS` | When untouched files move to Infrequent Access, or `NONE`. |
| `enable_backup` | `true` | Daily AWS Backup of the volume, kept 35 days. |
| `vpc_id`, `private_subnet_ids` | `null` | An existing network. Both or neither. |
| `assign_public_ip` | `false` | For an existing public subnet with no NAT gateway. |
| `availability_zones`, `vpc_cidr` | first two of the Region, `10.78.0.0/22` | For the network the module builds. |
| `cluster_arn` | `null` | An existing ECS cluster. Null creates one. |
| `log_retention_days`, `log_kms_key_arn` | `30`, `null` | The log group's retention and key. |
| `ecr_repository_arns` | `[]` | Private ECR repositories the execution role may pull from. Empty gives it no ECR permission. |
| `name_prefix` | `sre-agent-fix-runner` | Prefix of every resource, at most 24 characters. |
| `tags` | `{}` | Tags for every resource. |

## Outputs

| Output | |
|---|---|
| `service_arn` | The ECS service. |
| `cluster_arn` | The cluster it runs in. |
| `memory_bucket_name`, `memory_prefix` | Where the memory is mirrored. |
| `file_system_id`, `access_point_arn` | The workspace volume and the access point it is mounted through. |
| `log_group` | The runner's log group. |
| `api_key_scope` | `fix_runner:poll`, the one scope the API key must carry. |
| `task_role_arn`, `task_role_name` | The role the runner (and, with `agent_aws_access`, the agent) holds. |
| `security_group_id`, `private_subnet_ids` | The task's group and subnets. |
| `nat_public_ip` | The address the runner's traffic leaves from; null with an existing VPC. |

## Auditing what it did

- **Requests:** the Control Tower drawer and the card show each request's report, with the memory
  changes listed.
- **The log group:** every poll, request, refusal and redacted error the runner logs. The poll key,
  the repository token and the handoff token are replaced with `[redacted]` in every line.
- **The notes themselves:** `aws s3 ls s3://<memory_bucket_name>/<memory_prefix> --recursive`, and
  the versions of any file with `aws s3api list-object-versions`; or on the volume, through a task
  that mounts the same access point.
- **CloudTrail:** the task role's use of the bucket and the volume is under its role session name.

## Cost

Fixed monthly cost at us-east-1 list prices when this was written (check current pricing), always
on:

| Item | About |
|---|---|
| Fargate, ARM64, 2 vCPU and 8 GiB, running all month | $68 |
| NAT gateway (not with an existing VPC) | $33 plus $0.045 per GB it processes |
| The NAT gateway's Elastic IP (a public IPv4 address) | $3.65 |
| EFS | $0.30 per GB-month in standard storage, less in Infrequent Access; elastic throughput is billed per GB read and written |
| AWS Backup of the volume | per GB-month of backup storage |
| Secrets | $0.40 per secret per month |
| The bucket and the log group | pennies at this size |
| A KMS key you manage | $1 each |

Lower `cpu` and `memory`, run in an existing VPC that already has a NAT gateway, or use public
subnets with `assign_public_ip` to bring the fixed cost down. The model's tokens are billed to your
key by your provider.

## Requirements

| | |
|---|---|
| Terraform | >= 1.5 |
| `hashicorp/aws` | >= 5.0 |
