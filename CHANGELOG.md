# Changelog

Semantic versioning. **Read this before upgrading**: with these modules a minor
bump can widen access to your account, and that should be a decision rather
than a `terraform apply`.

- **major**: variables changed, or permissions removed
- **minor**: a permission added, because the product gained a feature needing it
- **patch**: documentation, validation, formatting; no change to what is granted

## [4.9.0]

The `fix-runner` module runs the **v2.2.0** runner image. While a runner works on a request it
reports in every minute, so when a runner stops, crashes or loses its network, SRE Agent moves the
request on within minutes: to another of your runners, then to SRE Agent's own runner when the
repository allows it, instead of waiting out a long timeout. A failed run also tells SRE Agent what
went wrong, so the request says it in a plain sentence.

### Security
- The runner applies its protected paths rule to a changed file whose name holds a non-ASCII or
  special character. Older runners read such a name quoted, so a workflow file named that way under
  `.github/` passed the rule; that mattered only when the runner's GitHub credential may write
  workflows (an `SRE_GITHUB_TOKEN` with the `workflow` scope, or an App installation granted
  Workflows). Upgrade to this release.

### Changed
- `fix-runner`: the default `image` is the `sre-agent-opencode` v2.2.0 multi-architecture index,
  pinned by digest
  (`ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:b6a70ef638a64ddddfa660d5d2224f0004cef4a622d13552bb1ab3e75e4f90eb`).
  No permission or variable changes.

## [4.8.0]

The `fix-runner` module runs the **v2.1.0** runner image: the pull request title and the commit
headline are a Conventional Commits header of at most 72 characters, cut at a word: the title the
request names when it names one, else the agent's own valid title, else the one SRE Agent sends.

### Changed
- `fix-runner`: the default `image` is the `sre-agent-opencode` v2.1.0 multi-architecture index,
  pinned by digest
  (`ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:3f13c22f54cdbc5933580e303d60637e9f625c5af55ce598b1c22bb5257ec76b`).
  No permission or variable changes.

## [4.7.0]

The `fix-runner` module runs the **v2.0.0** runner image. The runner works as in v1.9.0; the
major moves because `sre-agent-opencode` v2.0.0 removed its GitHub Actions workflow, which this
module never used. Runner images pin by digest, so nothing you pull changes besides the image.

### Changed
- `fix-runner`: the default `image` is the `sre-agent-opencode` v2.0.0 multi-architecture index,
  pinned by digest
  (`ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:ad2f4380d5795f27db4c836e3b3258fc28ad4442bf5491903926ba59a60b4229`).
  No permission or variable changes.

## [4.6.0]

The `fix-runner` module runs the **v1.9.0** runner image: under the account split (the container
model, a root runner) the pull request step works end to end, because the pull request body
is the runner account's own file; the commit subject and the pull request title come from the
request when SRE Agent sends one; and "Run a test job" checks the pull request step too.

### Changed
- `fix-runner`: the default `image` is the `sre-agent-opencode` v1.9.0 multi-architecture index,
  pinned by digest
  (`ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:d210915fdd95204ff9d8f8e0562c31fd66d267bf5945cf2ff20df122912c6088`).
  No permission or variable changes.

## [4.5.0]

The `fix-runner` module runs the **v1.8.0** runner image: opencode's own server log is forwarded
into the runner's log group (every line prefixed `opencode:`, redacted and bounded), and every
process the runner starts carries a `PWD` matching its working directory, so the agent session
roots at the repository checkout instead of the container's workspace.

### Changed
- `fix-runner`: the default `image` is the `sre-agent-opencode` v1.8.0 multi-architecture index,
  pinned by digest
  (`ghcr.io/segfaultpw/sre-agent-opencode-runner@sha256:1eb3de2c27ea8eb35e5bb6d845ed626924d897d8565cac9779ad7c6cf12f0c60`);
  the v1.8.0 image is required for the log forwarding and the working-directory fix. No permission
  or variable changes.

## [4.4.0]

The `fix-runner` module can run the self-hosted fix runner with a **GitHub App** instead of static
tokens: the runner holds the App's id and private key and mints a short-lived installation token
for each request (its own to clone and push, a second for the agent that is `contents` read-only on
the request's repository alone), so no long-lived GitHub credential sits in the task at all.

### Added
- `fix-runner`: `github_app_id` and `github_app_private_key_secret_arn` select App mode. The task
  definition sets `SRE_GITHUB_APP_ID` as a plain value (the id is not a secret) and injects
  `SRE_GITHUB_APP_PRIVATE_KEY` from the secret; in that mode neither `SRE_GITHUB_TOKEN` nor
  `SRE_AGENT_GITHUB_TOKEN` exists. GitHub authentication is one shape exactly: this pair, or
  `github_token_secret_arn` (which `agent_github_token_secret_arn` complements); both together and
  neither at all are refused at plan time, as is the App's id without its key and the key without
  its id. The secret's value is the private key PEM exactly as the `.pem` file GitHub lets you
  download, newlines and all; the runner needs no encoding. App mode needs the `sre-agent-opencode`
  **v1.7.0** runner image or newer; pass its digest as `image` when the default is older.
- `fix-runner`: `extra_environment` refuses `SRE_GITHUB_APP_ID` in App mode (the module sets it),
  and `SRE_GITHUB_APP_PRIVATE_KEY` is refused in every mode as a credential-shaped name. The App's
  private key never enters the agent's environment, and the agent's GitHub token in App mode is
  minted per run and cannot push.

Nothing existing changes in the token shape: the module plans exactly what it did in 4.3.1.

## [4.3.1]

### Fixed
- `fix-runner`: the pool's image refusal compares the digest, not the whole reference. The image
  variable accepts a `name:tag@sha256:...` spelling and a mirror's name, and the v1.5.0 digest
  under either form is one a pool cannot lease (it sends no instance id, so two tasks would be
  one runner to the queue and every job twice), so that digest is refused in a pool however it is
  spelled. Both spellings are pinned by tests.

## [4.3.0]

The `fix-runner` module can run the self-hosted fix runner as a pool: several Fargate tasks on the
one workspace volume, each leasing its own jobs, so a request is answered while another task is
busy on a long checkout or a big run. The self-hosted fix runner is a plan feature
(`self_hosted_fix_runner`).

### Added
- `fix-runner`: `runner_count` (default `1`). At `1` nothing changes: one task, the same task
  definition as 4.2.0, replaced stop-first. Above `1` the service runs that many tasks and the task
  definition sets `SRE_WORKSPACE_PER_INSTANCE=1` and `SRE_MEMORY_ROOT=/workspace/memory`: each task
  works in its own directories on the shared volume (its clones, git directories, agent homes and
  scratch under `instances/<its instance id>`), while the memory stays one shared tree the runner's
  per-repository locks guard, so two tasks never write the same notes at once and a request whose
  repository is busy on another task is answered honestly rather than waited on. The queue leases
  each job to the runner instance that collects it, and no other instance is offered that job until
  the lease ends, which is what makes two tasks on one API key safe. A deployment never runs more
  tasks than the count at once and replaces them one at a time, so each task has the replacement gap
  one task always had. Raise the count through the variable, never by editing the service's desired
  count outside Terraform. A pool needs the `sre-agent-opencode` **v1.6.0** runner image or newer:
  an older image sends no instance id, so the queue cannot lease, every job is offered to every
  task, and two tasks can take the same request and do it twice.
- `fix-runner`: `extra_environment` refuses `SRE_WORKSPACE_PER_INSTANCE` and `SRE_MEMORY_ROOT`
  when `runner_count` is above `1` (the module sets both for the pool); at `1` they stay the
  operator's, so a single task can still opt into the split workspace on its own.

Nothing existing changes at the default count: the module plans exactly what it did in 4.2.0.

## [4.2.0]

The `fix-runner` module runs SRE Agent's self-hosted fix runner on ECS Fargate in your own account.
The runner answers fix requests with your model key and opens the pull request with your GitHub
token; SRE Agent never connects to your account. The self-hosted fix runner is a plan feature
(`self_hosted_fix_runner`).

### Added
- `fix-runner`: a new module. It creates one Fargate service (desired count 1, replaced stop-first,
  no load balancer, no inbound rule), an encrypted EFS volume mounted at `/workspace` through one
  access point, so clones, the agent's per-repository homes and its notes survive a replaced task,
  an S3 bucket the notes are mirrored to (versioned, SSE-S3, every public access block, TLS only),
  or an existing bucket you name, a log group, and, unless you pass your own, a VPC with a NAT
  gateway and an ECS cluster. The image defaults to the `sre-agent-opencode` v1.5.0 runner pinned
  by its multi-architecture digest; a tag is refused.
- The **task role** grants the workspace volume through the one access point
  (`elasticfilesystem:ClientMount`, `ClientWrite` and `ClientRootAccess`, the last because the
  container starts as root and switches to its two accounts itself), list, get, put and delete on
  the memory prefix only, `kms:Encrypt`, `kms:Decrypt` and `kms:GenerateDataKey` on
  `memory_bucket_kms_key_arn` only when you set it, and exactly the policies in
  `extra_policy_arns`. The **execution role** writes the log stream, reads the named secrets
  (`kms:Decrypt` through Secrets Manager on `secrets_kms_key_arn` when you set it) and pulls from
  `ecr_repository_arns` when you set them. Nothing is granted on every resource.
- The agent holds no AWS credentials unless you set `agent_aws_access = true`, which gives it
  everything the task role holds. `agent_github_token_secret_arn` gives the agent a token of its
  own (for example read-only); left unset, the agent holds the runner's token, which can push.
  The module README's "What the agent can reach" says what the two accounts and the scrub stop and
  what they do not; read it before you grant the task role anything.
- Inputs that refuse what would move the boundary: `extra_environment` refuses credential-shaped
  names, the variables the module sets, `SRE_ONCE` and the names that change what the runner and
  the agent run (`PATH`, `HOME`, `LD_*`, `GIT_*`, `OPENCODE_*` and others), and a setup script
  outside the image; `extra_egress_ports` opens more outbound TCP ports, 443 always being open.

Nothing existing changes: the module only adds resources when you apply it.

## [4.1.0]

The `verifier` module serves SRE Agent's customer-run verifier. SRE Agent has published a verifier
image for each of the six runtimes (the module README lists the current digests), and the feature
is lit per organization: a plan that includes code improvement, turned on for the organization. A
poller of an organization where it is not lit is answered `403 feature_not_available` and backs
off.

### Added
- `verifier`: a new module, the customer-run verifier. SRE Agent can build and test a proposed
  fix in a sandbox before it opens the pull request; this module runs that sandbox in your own
  account, so the cost, the quotas and the isolation rules are yours. It creates a VPC with one
  public subnet for the NAT gateway and a private subnet per zone (outbound HTTPS only, no
  inbound), an ECS cluster, one Fargate task definition per runtime you give an image for, a task
  role with **no permissions** and an execution role, log groups, and a Lambda poller on an
  EventBridge schedule. The poller asks SRE Agent for work with an organization API key that
  carries the single scope `verifier:poll` (read from a Secrets Manager secret you create, so the
  key never enters state) and starts the image for the job it is handed. Nothing existing changes:
  the module only adds resources when you apply it. The poller's IAM is four statements, none on
  every resource: write its own logs, read the one secret, `ecs:RunTask` on the verifier task
  definitions in the one cluster, and `iam:PassRole` on the two task roles to ECS tasks only.
  The platform never connects to your account; the poller makes outbound HTTPS requests to your
  SRE Agent and calls ECS in your account. The tasks' network is yours: egress is TCP 443 to
  anywhere (Fargate's image pull and log delivery ignore a proxy, so it cannot be narrowed to
  one), and SRE Agent's per-repository network setting is not enforced on it.
- `verifier`: `poller_reserved_concurrency` (default `null`, no reservation: overlapping polls are
  safe, and a reservation fails to apply on an account whose Lambda concurrency is still the
  new-account 10), `alarm_actions` (two optional alarms on the same actions: the poller's
  `Errors`, and a metric filter on its `level=error` log lines, which also covers an image or
  poller SRE Agent refuses with `426`, a `RunTask` ECS refused and a job for a runtime with no task
  definition, none of which raise), `log_kms_key_arn` (a customer-managed key for both log groups),
  `ecr_repository_arns` (the execution role pulls from named private repositories only; it has no
  ECR permission by default) and validation of `availability_zones` (one to three),
  `api_key_secret_arn` (the full ARN with its suffix, in the deployment Region),
  `api_key_kms_key_arn` (a key ARN; the grant is limited to Secrets Manager and the one secret),
  `poll_schedule_expression` (`rate(1 minute)` to `rate(4 minutes)`, because SRE Agent treats a
  poller silent for 5 minutes as gone and 5 would sit on that bound), `log_retention_days` (a value CloudWatch offers) and
  `vpc_cidr` (/16 to /24). `no_proxy` defaults to `localhost,127.0.0.1,::1`. The execution role has
  an inline policy for its own log stream instead of the AWS managed policy, the two ECS roles
  trust ECS tasks of the account only, and the poller's timeout is 60 seconds. A failed poll is not
  retried by Lambda; the next scheduled poll is the retry. The poller re-reads a rotated API key
  without a redeploy, raises when the key stays refused, and never follows a redirect.

## [4.0.0]

### Removed (major: permissions were removed)
- `aws-readonly`: the `waf` and `apigateway` groups that `enable_waf_read` and
  `enable_apigateway_read` switched (`wafv2:ListWebACLs`, `wafv2:GetWebACL`,
  `wafv2:ListResourcesForWebACL`, `wafv2:GetLoggingConfiguration`,
  `wafv2:GetSampledRequests`, `wafv2:GetRateBasedStatementManagedKeys` and
  `apigateway:GET`) and the `NoApiKeyValues` deny that came with the API Gateway allow.
  SRE Agent removed the traffic protection preview that read them, and nothing in the
  product reads WAF or API Gateway any more. Nothing is granted that was not before.
- `aws-readonly`: the stale mentions of API Gateway in the `enable_networking` description
  and in the networking group's comment. `apigateway:GET` left that group in 3.0.0.

### Deprecated
- `aws-readonly`: `enable_waf_read` and `enable_apigateway_read` stay as no-op variables
  (default `false`) so an existing module call keeps planning. They grant nothing; setting
  one to `true` raises a warning from a `check` block. They will be removed in 5.0.

### Added
- `aws-readonly`: `tests/policy.tftest.hcl`, which pins that the rendered policy holds no
  `wafv2:` or `apigateway:` action and no `NoApiKeyValues` deny, and that the two
  deprecated variables change nothing.

### Upgrading from 3.x
- Nothing to change in your module call: plans keep working. Delete `enable_waf_read` and
  `enable_apigateway_read` from it at your leisure. A role that already holds the WAF and
  API Gateway actions loses them on apply, which the product no longer needs. A policy
  copied by hand can drop the `EdgeInventory`, `ApiGatewayRead`, `NoApiKeyValues` and
  `WafRead` statements; keeping them is harmless.

## [3.1.0]

### Added
- `aws-cleanup`: a new module, the role behind SRE Agent's AWS cleanup connector
  (`aws_cleanup`), which Self-healing's deletions go through. Five switches, all on by
  default, each granting only what that group of deletions needs: `enable_iam_deletions`
  (`iam:DeleteAccessKey`, `iam:DeleteLoginProfile` on the account's users, with the reads that
  prove them unused, and the reads of the customer-managed policies attached to a user or its
  groups, `iam:GetPolicy` and `iam:GetPolicyVersion`, that prove the user is not an
  administrator), `enable_ebs_deletions` (snapshot, delete and recreate an unattached volume; to
  recreate one encrypted with a customer-managed key it also allows `kms:Decrypt`,
  `kms:DescribeKey`, `kms:GenerateDataKeyWithoutPlaintext`, `kms:ReEncryptFrom`,
  `kms:ReEncryptTo` and `kms:CreateGrant` on the account's keys in `aws_region`, only when EC2
  makes the call (`kms:ViaService`) and, for a grant, only for an AWS resource
  (`kms:GrantIsForAWSResource`); a volume encrypted with a key in another account is restored by
  hand), `enable_address_release` (`ec2:ReleaseAddress`), `enable_snapshot_image_deletions`
  (`ec2:DeleteSnapshot`, `ec2:DeregisterImage`, the Recycle Bin restores and the reads of your
  Recycle Bin rules) and `enable_log_retention` (`logs:PutRetentionPolicy`,
  `logs:DeleteRetentionPolicy`). Writes are scoped to a resource type in the account and
  `aws_region`, never to one id, and `ec2:CreateTags` is allowed only while a snapshot or volume is
  created (`ec2:CreateAction`). A Deny at the end refuses every destructive write the role is
  granted on a resource tagged `sre-agent:protect` (any value). Nothing existing changes: the
  module only adds a role when you apply it, and deleting the role stops every deletion.
- `aws-iam-hygiene`: a Deny of `iam:UpdateAccessKey` for a user tagged `sre-agent:protect` (any
  value), behind `enable_key_changes` like the Allow, with a `protect_tag_key` input. It only
  matters once you tag a user; nothing is denied until you do.

## [3.0.0]

### Added
- `aws-readonly`: a `waf` group behind `enable_waf_read` (default `false`, opt-in):
  `wafv2:ListWebACLs`, `wafv2:GetWebACL`, `wafv2:ListResourcesForWebACL`,
  `wafv2:GetLoggingConfiguration`, `wafv2:GetSampledRequests` and
  `wafv2:GetRateBasedStatementManagedKeys`. Turn it on for WAF-based client rates in
  traffic protection (which edge stands in front of a service, and who is hammering
  it). Left off, detection still works from DNS, metrics and logs and the product
  says which inputs it did not read. Every action is a read.
- `aws-readonly`: an `apigateway` group behind `enable_apigateway_read` (default
  `false`, opt-in) holding `apigateway:GET`, with an explicit `NoApiKeyValues` deny
  of the API key resources (`/apikeys`, `/apikeys/*` and the keys of a usage plan).
  The deny exists only where the allow does.

### Upgrading from 2.x (major: a permission was removed)
- `aws-readonly` no longer grants `apigateway:GET` by default. To keep API Gateway
  reads set `enable_apigateway_read = true`; to keep (or start) WAF-based client
  rates set `enable_waf_read = true` (both are off by default).

### Changed
- **Behaviour change for `aws-readonly` users who relied on API Gateway reads.**
  `apigateway:GET` moved out of the `networking` group into the new opt-in
  `apigateway` group, because IAM names every API Gateway read GET and stage
  variables, where some teams keep secrets, are readable through it. If you use
  API Gateway reads (for example for traffic protection), set
  `enable_apigateway_read = true`; otherwise the role no longer holds them, and a
  policy copied by hand should drop the action or keep the deny.

## [2.4.0]

### Added
- `aws-iam-hygiene`: a new module, the role behind SRE Agent's AWS IAM hygiene
  connector (`aws_iam`). It grants `iam:GetUser`, `iam:ListAccessKeys` and
  `iam:GetAccessKeyLastUsed` to read who holds an access key and when it was
  last used, and `iam:UpdateAccessKey` (behind `enable_key_changes`, default
  `true`) to set a key Active or Inactive, all on `arn:aws:iam::<account>:user/*`.
  The Verify button's `iam:SimulatePrincipalPolicy`, scoped to the role's own
  ARN, is behind `enable_verification` as in the other modules. It never
  deletes or creates a key and touches no user, policy or login. Nothing
  existing changes: the module only adds a role when you apply it.

## [2.3.1]

### Fixed
- Documentation: the READMEs said EKS workloads need the `kubernetes-rbac`
  module. SRE Agent now discovers EKS clusters and their workloads from
  `aws-readonly` alone, through `eks:ListClusters` and `eks:DescribeCluster`
  (compute group) and Container Insights' metric dimensions via
  `cloudwatch:ListMetrics` (observability group), both already granted.
  `kubernetes-rbac` is still what reads the cluster's own API. No change to
  what either module grants.

## [2.3.0]

### Added
- `aws-readonly`: the compliance posture scan's reads. The `identity` group
  (`enable_identity_read`) gains `iam:GenerateCredentialReport` plus
  `sso:Describe*`, `sso:List*`, `identitystore:Describe*` and
  `identitystore:List*`; the `compute` group (`enable_compute`) gains
  `ec2:GetEbsEncryptionByDefault`. Together with reads the groups already
  carried (trails, log groups, RDS and volume describes), these are what the
  product's Compliance page computes account evidence from: root and password
  hygiene from the credential report (key ages and MFA facts, never secrets),
  who reaches the account through Identity Center, and whether new EBS volumes
  encrypt by default. Every addition is a read; the `Generate*` verbs only
  compute reports. Refuse any of it and the affected controls report no data
  and name the missing grant.

## [2.2.0]

### Added
- `aws-readonly`, `aws-ssm-remediation`: an optional `Verification` statement,
  `iam:SimulatePrincipalPolicy` scoped to the module's own role ARN, behind
  `enable_verification` (default `true`). It is what lets the product's Verify
  button (Settings &rarr; Infrastructure &rarr; "Required AWS permissions") ask
  IAM whether the role really allows what the app derived and answer with
  evidence instead of "unverified". Read-only, and it can simulate nothing but
  the role it rides on; a role built from these modules before this version can
  do everything except be verified, which is exactly the diagnostic the button
  shows.

### Fixed
- `aws-readonly` README: the toggle table still documented the per-service
  variables 2.0.0 replaced (`enable_ec2`, `enable_ecs`, ...), so a reader
  following it wrote variables `terraform plan` refuses. It now documents the
  real grouped toggles.

## [2.1.0]

### Added
- `aws-readonly`: ACM read joins the networking group —
  `acm:DescribeCertificate`, `acm:ListCertificates` and
  `acm:ListTagsForCertificate` — so the product can discover the account's
  certificates and watch their expiry before it takes an endpoint down.
  `acm:GetCertificate` and `acm:ExportCertificate` stay deliberately absent:
  Export returns the private key of an exportable certificate, which is data,
  not shape.

### Changed
- Releases now cut themselves: when a `feat:` or `fix:` commit reaches main
  with green CI, the release workflow computes the bump from the commit
  messages (`feat!`/`BREAKING` major, `feat` minor, `fix` patch) and refuses
  to release until this file carries a section for that version. Writing the
  changelog entry IS the release decision; the tagging is just mechanics.

## [2.0.1]

### Fixed
- The read-only example still passed `enable_xray`, removed in 2.0.0. The
  modules themselves were unaffected, but the example did not validate. Caught
  by CI, which is what it is for.

## [2.0.0]

### Changed (breaking)
- `aws-readonly` now takes **service-group** toggles instead of one per
  service. `enable_ec2`, `enable_ecs`, `enable_eks`, `enable_lambda`,
  `enable_autoscaling` and `enable_load_balancing` are replaced by
  `enable_compute` and `enable_networking`; `enable_cloudwatch`,
  `enable_logs`, `enable_cloudtrail` and `enable_xray` by
  `enable_observability`. At this breadth a per-service list was unreviewable.

### Added
- Much wider read coverage, so FinOps savings, capacity planning and incident
  correlation all have more to work with: S3 (configuration), EFS, FSx, Backup,
  DynamoDB, Redshift, MemoryDB, Kinesis, Firehose, SQS, SNS, MSK, EventBridge,
  Route 53, CloudFront, API Gateway, Direct Connect, Global Accelerator,
  Elastic Beanstalk, Batch, ECR, Step Functions, AWS Health and Service Quotas.
- A `cost` group: Cost Explorer, Budgets, Pricing, Savings Plans, Compute
  Optimizer and Cost Optimization Hub. This is the difference between
  estimating savings from a hard-coded price list and reporting what the
  account is actually billed.
- An `identity` group (IAM read), which turns a CloudTrail entry from "some
  principal" into "this role".
- A `governance` group: tagging, Resource Groups, Config, Organizations.

### Security
- The policy draws an explicit **control plane, not data plane** line, and it
  is verified rather than asserted: no `s3:GetObject`, `dynamodb:GetItem`,
  `kinesis:GetRecords`, `sqs:ReceiveMessage`, `secretsmanager:GetSecretValue`
  or `ssm:GetParameter`. This is deliberately narrower than AWS's own
  `ReadOnlyAccess`, which includes several of those.

## [1.0.0]

### Added
- `aws-readonly`: the role SRE Agent assumes to read an AWS account, covering
  EC2, CloudWatch, CloudWatch Logs, ECS, Lambda and CloudTrail by default, with
  X-Ray and Bedrock opt-in.
- `aws-ssm-remediation`: opt-in `ssm:SendCommand`, scoped by instance tag and
  SSM document, refusing an unscoped grant at plan time.
- `kubernetes-rbac`: ServiceAccount, read-only ClusterRole and binding, with
  optional metrics and events, plus a long-lived token for Kubernetes 1.24+.
