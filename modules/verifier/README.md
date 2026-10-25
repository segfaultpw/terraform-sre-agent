# verifier

Runs SRE Agent's sandbox verification in **your** account. Before SRE Agent opens a fix as a pull
request it can build the change and run the repository's own tests, before and after the change.
By default that happens on a sandbox we operate and meter. With this module the same verifier
images run on infrastructure you own: your cost, your quotas, your isolation rules, and
verifications on it are not counted against your plan's sandbox allowance (model tokens still
are).

**SRE Agent never connects to your account.** A poller in it asks for work, over HTTPS, outbound.

**It is your network.** The tasks' network rules are yours: SRE Agent's per-repository setting
**Let checks reach the network** is not enforced on a verifier you run. With that setting off, SRE
Agent only withholds the proxy variables from the commands that run after setup, which stops
nothing when there is no proxy, and the default network here lets every command reach the internet
on port 443. A repository's tests, install scripts and anything a fix writes can therefore send
data to any host. If that is not acceptable for a repository, put your own firewall in the NAT
path (the tasks leave from the NAT gateway's address, output `nat_public_ip`) or keep that
repository on SRE Agent's own sandbox.

## Availability

The customer-run verifier is lit per organization: your plan includes code improvement (Pro and
up) and it is turned on for your organization. A poller for an organization where it is not lit is
answered `403 feature_not_available`; it logs "nothing to do (feature_not_available)", backs off
and starts nothing, and the Integrations page does not offer **My own verifier** yet.

```
EventBridge (every minute) -> poller Lambda --GET /api/verifier/queue--> SRE Agent
                                   |                                        |
                                   | job: a single-claim bootstrap URL      |
                                   v                                        |
                          ECS RunTask (Fargate) <---------------------------+
                          verifier image, BOOTSTRAP_URL as its only variable
                                   |
                                   | claims the URL once: read-only token for ONE repository, the patch
                                   | runs the tests before and after, reports to a signed URL, exits
```

## Usage

1. In SRE Agent, **Settings, API Keys**: create a key carrying the single scope `verifier:poll`. It
   reaches the job queue and nothing else, and no person's token can carry it.
2. Put the key in Secrets Manager, outside Terraform so it never enters state, and without the key
   ever appearing on a command line (shell history and the process list show arguments). Paste the
   key into a file only you can read, create the secret from the file, then delete the file. The
   value is the plain key, not a key/value JSON secret (the console's default type):

   ```sh
   umask 077
   cat > verifier-key.txt        # paste the key, press Enter, then Ctrl-D
   aws secretsmanager create-secret --name sre-agent-verifier-key \
     --secret-string file://verifier-key.txt
   rm verifier-key.txt
   ```

   Create it in the Region you deploy the module to: the poller reads it through that Region's
   endpoint, and the module refuses a secret from another Region. The module needs the secret's
   **full ARN, with its six-character suffix**, which `create-secret` prints and
   `aws secretsmanager describe-secret --secret-id sre-agent-verifier-key --query ARN --output text`
   shows again.
3. Apply the module with the images you want, pinned by digest (the table below has the current
   ones):

```hcl
data "aws_secretsmanager_secret" "verifier_key" {
  name = "sre-agent-verifier-key"
}

module "sre_agent_verifier" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/verifier?ref=v4.1.0"

  sre_agent_url      = "https://sre.example.com"
  api_key_secret_arn = data.aws_secretsmanager_secret.verifier_key.arn

  images = {
    node   = "ghcr.io/segfaultpw/sre-agent-verifier-node@sha256:f623a162e6aaba83d0e592820b412547019cb45727b0befa775e8db8ca79392c"
    python = "ghcr.io/segfaultpw/sre-agent-verifier-python@sha256:52481966138aa61a97c2ab6d8b7932ac42670205e86c017d08653086b54de37d"
  }
}
```

   The data source reads the secret's address, never its value, so the key stays out of state.
4. In SRE Agent, **Integrations, GitHub, Where verifications run**: choose **My own verifier**. The
   card shows when the poller last called and what it runs, and **Run a test job** sends a no-op
   job through the whole path.

### Published images

The images SRE Agent accepts today, all current and able to run sessions (published 2026-10-21;
they match `runner_images.json` in SRE Agent):

| Runtime | Image |
|---|---|
| `elixir` | `ghcr.io/segfaultpw/sre-agent-verifier-elixir@sha256:ba5c874fecb15db7dd5b860a39e382ccf4494eadd9a4cfdc26b233564579d76d` |
| `node` | `ghcr.io/segfaultpw/sre-agent-verifier-node@sha256:f623a162e6aaba83d0e592820b412547019cb45727b0befa775e8db8ca79392c` |
| `python` | `ghcr.io/segfaultpw/sre-agent-verifier-python@sha256:52481966138aa61a97c2ab6d8b7932ac42670205e86c017d08653086b54de37d` |
| `go` | `ghcr.io/segfaultpw/sre-agent-verifier-go@sha256:cd2ff721db37e31df19dee057e00c975264bb7e958f067ef289dbd5c4a03c185` |
| `java` | `ghcr.io/segfaultpw/sre-agent-verifier-java@sha256:20e28b6261c05d2ff7d64e092b9c025c9d17ef20c7808003cf22c222885abfc4` |
| `php` | `ghcr.io/segfaultpw/sre-agent-verifier-php@sha256:313b8acbda0a4b61e4dd7f7e06a01146b7efd70de7a843faf3a4adf01b35bebe` |

This table is a snapshot. The Integrations card shows which images SRE Agent accepts now, and a
digest it refuses is answered (HTTP 426 to the poller, logged by it) with a sentence that names
what to move to. List only the runtimes your repositories use.

## What it builds

| Resource | Notes |
|---|---|
| VPC, one public subnet, one private subnet per zone, NAT gateway | The tasks run in the private subnets with no public address. |
| Security group | **No inbound.** Outbound TCP 443 to anywhere (see "The network" below). |
| ECS cluster, a task definition per runtime in `images` | 4 vCPU, 8 GiB, the largest size SRE Agent asks for; the job sets the real size for each run. |
| `-task` role | **No permissions.** The repository's code runs as this role. Nothing is attached, and nothing should be. |
| `-execution` role | An inline policy that writes the task's log stream and, only when you set `ecr_repository_arns`, pulls from those repositories. Not available to the code under test. Trusts ECS tasks of your account only (`aws:SourceAccount` and `aws:SourceArn`). |
| Poller Lambda and a schedule | Python 3.12, 60 seconds: two polls of up to 20 seconds each when a key is refused and re-read, a secret read between them and a `RunTask`. It only dispatches: a run is a Fargate task, so the 15-minute Lambda limit never applies to one. No concurrency is reserved by default (see `poller_reserved_concurrency`), and Lambda does not retry a failed poll: the schedule is the interval, and the next poll is the retry. |
| Poller alarms (optional) | With `alarm_actions` set, two alarms on the same actions: one on the poller's `Errors` when it has raised for 15 minutes running, and one on a metric filter over the poller's error log lines (below). |
| Log groups | The tasks' and the poller's, optionally encrypted with your KMS key (`log_kms_key_arn`). |

The poller's IAM role has four statements and none is on every resource: write its own logs, read
the one secret (plus `kms:Decrypt` on one key if you give `api_key_kms_key_arn`, and only through
Secrets Manager for that one secret), `ecs:RunTask` on the verifier task definitions in this
cluster only, and `iam:PassRole` on the two task roles to ECS tasks only. The poller's own role
trusts Lambda without a source condition: AWS documents `aws:SourceAccount` and `aws:SourceArn` for
ECS tasks assuming a role, not for Lambda assuming an execution role, and a condition on a key AWS
does not send would make the role impossible to assume.

## The network

The tasks' egress is outbound TCP 443 to `0.0.0.0/0` through the NAT gateway, and it is not a
variable. A task clones from GitHub and installs packages from the registries your repositories use,
and on Fargate the image pull and the log delivery to CloudWatch Logs go out through the task's own
network interface and do not use `HTTPS_PROXY`. A security group narrowed to a proxy's address
therefore stops every task before it starts (`CannotPullContainerError`), and the pull request then
tells the reader to check the image pull and the log group. If you need named-domain egress, put a
transparent firewall in the NAT path of your own network.

`https_proxy` (with `no_proxy`, default `localhost,127.0.0.1,::1`) is still available: it gives the
commands the verifier runs `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY`. It reaches those commands
only, the proxy must listen on port 443 (the only port the security group opens), and it does not
make the network any less yours: SRE Agent's per-repository network setting is not enforced here.

## Trust and upgrades

On every poll the poller reports its own version and the digest of the image it would start for each
runtime. SRE Agent judges them against the images it published: a digest it does not recognise, or one
that is too old, is refused for that runtime (HTTP 426) with a message that names the image to move
to, and the poller starts nothing for it. Read the poller's log group (output `poller_log_group`) to
see the message. A refusal like this does **not** go away by waiting: it repeats on every poll, and
every pull request opens unverified meanwhile, until you change the digest in `images` (or upgrade
this module for a new poller) and apply. A job nobody collects within 15 minutes is ended, and the
pull request opens as a draft that says it was not verified.

With `alarm_actions` set, that case alarms. The poller logs a 426, a `RunTask` ECS refused and a job
for a runtime with no task definition as one JSON line with `"level": "error"` and then returns
normally, so Lambda's `Errors` metric does not count them. A metric filter on `{ $.level = "error" }`
over the poller's log group and its own alarm (same actions, 15 minutes running) cover them. The
answers that mean "come back later" are different and stay quiet: a plan without the feature or an
organization where it is not lit yet (`403 feature_not_available`), and an organization set to the
hosted sandbox (`409 hosted_mode`), are logged as warnings.

## Options worth knowing

| Variable | Default | What it does |
|---|---|---|
| `poller_reserved_concurrency` | `null` | Reserved concurrency for the poller. Null reserves nothing. Overlapping polls are safe, because SRE Agent hands a job out with one conditional write, so the second of two simultaneous polls is given nothing and starts nothing. A reservation fails to apply on an account whose total Lambda concurrency is still the new-account limit of 10 (AWS will not let unreserved concurrency fall below 10), so set it only to cap a busy account. |
| `alarm_actions` | `[]` | ARNs (an SNS topic) to notify. Builds the `Errors` alarm, the error-line metric filter and its alarm. With none, nothing is built and the failures only show in the log group. |
| `poll_schedule_expression` | `rate(1 minute)` | `rate(1 minute)` to `rate(5 minutes)` only. SRE Agent routes nothing to a poller it has not heard from in 5 minutes, so a slower schedule opens every pull request unverified. |
| `log_retention_days` | `30` | A value CloudWatch Logs offers. |
| `log_kms_key_arn` | `null` | A customer-managed KMS key for both log groups; test output from your repositories lands in the task log group. The key policy must allow the CloudWatch Logs service of the Region. |
| `ecr_repository_arns` | `[]` | Private ECR repositories to pull from when you mirror the images (keep the multi-arch index, for example `skopeo copy --all`, so the digest the poller reports is unchanged). Empty gives the execution role no ECR permission. |
| `availability_zones` | first two of the Region | One to three zones for the private subnets. |
| `https_proxy`, `no_proxy` | `null`, `localhost,127.0.0.1,::1` | A proxy for the commands the verifier runs (above). |

## The poller

`lambda/poller.py` is a byte-identical copy of `verifier/poller/poller.py` in the SRE Agent repository,
with its tests (`lambda/test_poller.py`; `lambda/test_log_filter.py` is this module's own and pins the
alarm's filter to the lines the poller prints). Each repository pins the sha256 of its copy
(`lambda/poller.py.sha256`, the same digest in both) and CI fails when the file and its pin disagree,
so a change to either copy is made in both, with both pins, together. There is no client backoff: the
schedule is the interval, and a failed poll is not retried within it. The refusals that mean "come back
later" (a plan without the feature, a verifier set to the hosted sandbox) are logged as warnings and end
the poll quietly; an image or poller to upgrade is not one of them (above). A redirect from SRE Agent is
never followed, so the API key goes nowhere else. It is a Lambda, not a Fargate service, because it is
idle almost always and costs nothing then; a Fargate service would also work (the protocol is one GET
and one RunTask per job) and has no 15-minute limit, which the poller does not need.

## Cost

Fixed monthly cost at us-east-1 list prices when this was written (check current pricing):

| Item | About |
|---|---|
| NAT gateway | $33 plus $0.045 per GB it processes |
| The NAT gateway's Elastic IP (a public IPv4 address) | $3.65 |
| The API key secret | $0.40 |
| With `alarm_actions`: two alarms and one custom metric | $0.50 |
| A KMS key you manage for `log_kms_key_arn` or `api_key_kms_key_arn` | $1 each |

The Lambda invocations (about 43,000 a month at one a minute) are inside the free tier, and log
ingestion is $0.50 per GB. A verification costs Fargate time: a 2 vCPU, 4 GiB task for ten minutes is
a few cents.
