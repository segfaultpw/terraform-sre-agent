# Changelog

Semantic versioning. **Read this before upgrading**: with these modules a minor
bump can widen access to your account, and that should be a decision rather
than a `terraform apply`.

- **major**: variables changed, or permissions removed
- **minor**: a permission added, because the product gained a feature needing it
- **patch**: documentation, validation, formatting; no change to what is granted

## [2.5.0]

### Added
- `aws-readonly`: a `waf` group behind `enable_waf_read` (default `true`):
  `wafv2:ListWebACLs`, `wafv2:GetWebACL`, `wafv2:ListResourcesForWebACL`,
  `wafv2:GetLoggingConfiguration`, `wafv2:GetSampledRequests` and
  `wafv2:GetRateBasedStatementManagedKeys`. Traffic protection reads them to tell
  which edge stands in front of a service (a web ACL, what it protects, where it
  logs) and to see who is hammering it (the requests the WAF sampled for a rule and
  the addresses a rate rule is limiting right now). The group is optional: set
  `enable_waf_read = false` and detection still works from DNS, metrics and logs,
  and the product says which inputs it did not read. Every action is a read.

### Changed
- `aws-readonly`: with `enable_networking` the policy now carries an explicit
  `NoApiKeyValues` deny of `apigateway:GET` on the API key resources
  (`/apikeys`, `/apikeys/*`, and the keys of a usage plan). IAM names every API
  Gateway read `GET`, which includes API key values; the product only needs the
  shape of the APIs. This removes a read, so a policy copied by hand from before
  this version should add the same deny.

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
