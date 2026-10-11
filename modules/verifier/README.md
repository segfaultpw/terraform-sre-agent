# verifier

Runs SRE Agent's sandbox verification in **your** account. Before SRE Agent opens a fix as a pull
request it can build the change and run the repository's own tests, before and after the change.
By default that happens on a sandbox we operate and meter. With this module the same verifier
images run on infrastructure you own: your cost, your quotas, your isolation rules, and
verifications on it are not counted against your plan's sandbox allowance (model tokens still
are).

**SRE Agent never connects to your account.** A poller in it asks for work, over HTTPS, outbound.

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
2. Put the key in Secrets Manager, outside Terraform so it never enters state:
   `aws secretsmanager create-secret --name sre-agent-verifier-key --secret-string <the key>`
3. Apply the module with the images you want, pinned by digest (the list is in the SRE Agent
   documentation and is printed by the image workflow):

```hcl
module "sre_agent_verifier" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/verifier?ref=v4.1.0"

  sre_agent_url      = "https://sre.example.com"
  api_key_secret_arn = aws_secretsmanager_secret.verifier_key.arn

  images = {
    node   = "ghcr.io/segfaultpw/sre-agent-verifier-node@sha256:..."
    python = "ghcr.io/segfaultpw/sre-agent-verifier-python@sha256:..."
  }
}
```

4. In SRE Agent, **Integrations, GitHub, Where verifications run**: choose **My own verifier**. The
   card shows when the poller last called and what it runs, and **Run a test job** sends a no-op
   job through the whole path.

## What it builds

| Resource | Notes |
|---|---|
| VPC, one public subnet, one private subnet per zone, NAT gateway | The tasks run in the private subnets with no public address. |
| Security group | **No inbound.** Outbound TCP 443 to `egress_cidrs` only. |
| ECS cluster, a task definition per runtime in `images` | 4 vCPU, 8 GiB, the largest size SRE Agent asks for; the job sets the real size for each run. |
| `-task` role | **No permissions.** The repository's code runs as this role. Nothing is attached, and nothing should be. |
| `-execution` role | Pulls the image and writes the task's logs. Not available to the code under test. |
| Poller Lambda and a schedule | Python 3.12, one poll at a time, 30 seconds. It only dispatches: a run is a Fargate task, so the 15-minute Lambda limit never applies to one. |
| Log groups | The tasks' and the poller's. |

The poller's IAM role has four statements and none is on every resource: write its own logs, read
the one secret (plus `kms:Decrypt` on one key if you give `api_key_kms_key_arn`), `ecs:RunTask` on the
verifier task definitions in this cluster only, and `iam:PassRole` on the two task roles to ECS tasks
only.

## Trust and upgrades

On every poll the poller reports its own version and the digest of the image it would start for each
runtime. SRE Agent judges them against the images it published: a digest it does not recognise, or one
that is too old, is refused for that runtime with a message that names the image to move to, and the
poller starts nothing for it. Read the poller's log group (output `poller_log_group`) to see the
message. To upgrade, change the digest in `images` (or upgrade this module for a new poller) and apply.
A job nobody collects within 15 minutes is ended, and the pull request opens as a draft that says it
was not verified.

## Narrowing where the tasks may connect

The default is outbound HTTPS to anywhere through the NAT gateway, because a task clones from GitHub
and installs packages from the registries your repositories use. To allow named domains only, run an
egress proxy or firewall you operate, set `egress_cidrs` to its address and `https_proxy` to its URL:
the runner forwards `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` to the commands it runs. The output
`nat_public_ip` is the address your registries see when you need to allow it.

## The poller

`lambda/poller.py` is a copy of `verifier/poller/poller.py` in the SRE Agent repository, with its
tests. It is a Lambda, not a Fargate service, because it is idle almost always and costs nothing then;
a Fargate service would also work (the protocol is one GET and one RunTask per job) and has no
15-minute limit, which the poller does not need.

## Cost

The fixed cost is the NAT gateway (about $33 a month plus data) and the Lambda invocations (about
43,000 a month at one a minute, inside the free tier). A verification costs Fargate time: a 2 vCPU,
4 GiB task for ten minutes is a few cents.
