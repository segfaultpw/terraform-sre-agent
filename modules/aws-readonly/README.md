# aws-readonly

The role SRE Agent assumes to read your AWS account.

Covers the service-wide read surface for workloads, observability and tagging.
Nothing here can create, modify or delete anything in your account.

## Usage

```hcl
module "sre_agent_readonly" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-readonly?ref=v3.0.0"

  external_id           = "the-value-from-the-settings-page"
  trusted_principal_arn = "arn:aws:iam::111122223333:role/sre-agent-platform"
}
```

## What each toggle buys you

Wider than the exact calls made today, on purpose. See the repository README
for why. Turning one off is safe: the feature degrades to "no data" rather than
erroring, which is worth knowing, because **an empty page and a missing
permission look the same**. If something reads as empty, check the policy before
concluding there is nothing to report.

| Variable | Default | Feature it powers |
|---|---|---|
| `enable_compute` | `true` | EC2, Auto Scaling, ECS, EKS, Lambda, Beanstalk and Batch as workloads: capacity planning and most FinOps waste detectors. Also the account's EBS encryption-by-default bit, which the compliance posture scan reads. Without it those pages read as empty. |
| `enable_storage` | `true` | S3, EFS, FSx and Backup *configuration*: lifecycle, versioning, tags. Never object contents. |
| `enable_databases` | `true` | RDS, DynamoDB, ElastiCache, Redshift and MemoryDB metadata and configuration. No data-plane access exists in these actions. |
| `enable_streaming` | `true` | Kinesis, Firehose, MSK, SQS, SNS and EventBridge shape and tags. Never a record or a message. |
| `enable_networking` | `true` | Load balancers, CloudFront, Direct Connect, Global Accelerator, and ACM certificate expiry: where "the service is down" is usually first visible. |
| `enable_waf_read`, `enable_apigateway_read` | `false` | Deprecated since 4.0, no effect, removed in 5.0. SRE Agent no longer reads WAF or API Gateway. They remain so an existing module call keeps planning; setting one to `true` raises a warning and grants nothing. |
| `enable_observability` | `true` | CloudWatch metrics and alarms, Logs (including Insights), CloudTrail lookups, X-Ray, Health and Application Insights: SLIs, log search, "who changed what". |
| `enable_cost` | `true` | Cost Explorer, CUR, budgets, Savings Plans, Compute Optimizer and the Price List: the FinOps pages price from your bill instead of a stored table. |
| `enable_governance` | `true` | Config, Organizations, quotas, resource groups and tagging: resolves ownership across every service at once. |
| `enable_identity_read` | `true` | The IAM inventory behind the Security page's findings, CloudTrail principal resolution, and (since v2.3) the compliance posture scan's credential report and Identity Center reads. Names, policies, key ages, MFA facts and last-used, never credentials. Its `iam:Get*` includes `iam:GetAccountAuthorizationDetails`, which lets the IAM scan read a whole account in a few paged calls instead of several calls per user and role; without it the scan reads each principal itself. |
| `enable_inventory` | `true` | SSM inventory, Secrets Manager metadata (never values), ECR and Step Functions: existence of things the other groups do not name. |
| `enable_verification` | `true` | `iam:SimulatePrincipalPolicy`, scoped to this role's own ARN: the Verify button answers with evidence instead of "unverified". |
| `enable_bedrock` | `false` | Only if you point SRE Agent's AI provider at Bedrock in *your* account. The one block that is not read-only: `InvokeModel` bills you directly. |
| `enable_prometheus` | `false` | Amazon Managed Prometheus: `aps:QueryMetrics`, `aps:GetLabels`, `aps:GetSeries`, `aps:GetMetricMetadata` and `aps:ListRules`, so PromQL runs against your workspaces, and their alerting rules are read, with this role. Read-only; every workspace unless `prometheus_workspace_arns` limits it. Off because most accounts have no workspace. |

### Limiting CloudWatch Logs to chosen log groups

By default `enable_observability` lets SRE Agent read every log group in the
account, which is what makes "search my logs" work without configuration. If a
group holds something it should never read (audit trails, payment payloads),
list the groups it may read instead:

```hcl
module "sre_agent_readonly" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-readonly?ref=v4.15.0"
  # ...
  log_group_arns = [
    "arn:aws:logs:us-east-1:111122223333:log-group:/aws/lambda/checkout",
    "arn:aws:logs:*:111122223333:log-group:/prod/*", # IAM wildcards work
  ]
}
```

What changes when you set it:

- The Logs reads leave the main policy and go into a **second managed policy**
  (`logs_policy_name`, default `sre-agent-readonly-logs`), created and attached
  only in this case, so a plan that leaves `log_group_arns` unset is exactly what
  it was. The main policy keeps no `logs:` action.
- The actions SRE Agent calls and where each one lives: `FilterLogEvents`,
  `StartQuery`, `GetQueryResults`, `GetLogEvents` and `GetLogGroupFields` are
  limited to the listed groups (and their streams); `DescribeLogGroups` and
  `StopQuery` take no resource in IAM, so they stay on `*`. The other
  `Describe*`, `Get*` and `List*` actions that take a log group
  (`DescribeLogStreams`, `GetLogRecord` and so on) are granted on the listed groups
  only. **Every Logs action that names no log group, apart from those two, is not
  granted at all**, which covers about twenty-five reads (`DescribeQueries`,
  `DescribeQueryDefinitions`, `DescribeResourcePolicies`, `DescribeExportTasks`
  and others). A feature that starts using one of them later works on an unscoped
  install and is denied on a scoped one until this module grants it.
- SRE Agent can still see that your other log groups exist (`DescribeLogGroups`),
  but not what is in them.
- A request against a group you did not list is denied (`AccessDenied`). A Logs
  Insights query names its groups together, so **a query that names even one
  unlisted group is refused as a whole**, not answered for the listed ones.
  Expect the data source to show a denial after an investigation that picked an
  unlisted group.
- The product's **Verify button may show the scoped Logs actions as not granted**.
  It asks IAM to simulate each action against all resources, and an action allowed
  only on particular log groups does not pass that check. Until the product checks
  them against the groups you listed, read the "missing" Logs actions as expected
  when you have set `log_group_arns`.
- AWS caps a managed policy at 6,144 characters without whitespace. Each entry
  costs twice its ARN length plus 8 (the group and its streams): about 28 ARNs of
  100 characters. A longer list is refused at plan time with a message that says
  so; use name wildcards (`log-group:/prod/*`) rather than listing every group.
- `log_group_arns` has no effect when `enable_observability` is false.

### Amazon Managed Prometheus

`enable_prometheus = true` grants `aps:QueryMetrics`, `aps:GetLabels`,
`aps:GetSeries`, `aps:GetMetricMetadata` and `aps:ListRules` (the alerting rules
SRE Agent's alert follow-up reads) on every workspace the role can see; `prometheus_workspace_arns = ["arn:aws:aps:us-east-1:111122223333:workspace/ws-0123abcd"]`
limits it to the ones you list. Nothing in the group can write, remote-write or
delete.

### EKS clusters and their workloads

`enable_compute` (`eks:ListClusters`, `eks:DescribeCluster`) together with
`enable_observability` (`cloudwatch:ListMetrics`) is all SRE Agent needs to list
your EKS clusters and the workloads in them: workload names, namespaces and
clusters come from Container Insights' metric dimensions, with no kubeconfig.
Container Insights must be enabled on the cluster. Reading the cluster's own
API (security findings, live Kubernetes resources) is authorised separately by
the cluster's RBAC, so apply `kubernetes-rbac` as well if you want those.

### A note on `ec2:Describe*`

This includes `DescribeInstanceAttribute`, which can return an instance's user
data. If your bootstrap scripts embed secrets, that is worth knowing before you
apply. The fix is to stop embedding them, but you should make that call
knowingly rather than discover it later.

## Upgrading to 4.15

The role's description no longer contains your ExternalId (it used to read
`Read-only access for SRE Agent (<the ExternalId>)`). The ExternalId identifies
your organization to the role's trust policy; it is not a credential and it never
changes. Keeping it out of the description simply stops it being broadcast to
everyone who can call `iam:GetRole` or `iam:ListRoles` and into CloudTrail and
AWS Config. The trust policy condition still holds it, and is the only place the
modules write it. The same change applies to `aws-cleanup`, `aws-iam-hygiene`
and `aws-ssm-remediation`.

`terraform plan` shows **one in-place update per role** (`~ description`,
`UpdateRoleDescription`): the role is not replaced, its ARN and sessions are
untouched, and nothing it grants changes. The old description stays in your
CloudTrail and Terraform state history.

## Inputs

| Name | Type | Default | Required |
|---|---|---|:--:|
| `external_id` | `string` | | yes |
| `trusted_principal_arn` | `string` | | yes |
| `role_name` | `string` | `"sre-agent-readonly"` | no |
| `policy_name` | `string` | `"sre-agent-readonly"` | no |
| `logs_policy_name` | `string` | `"sre-agent-readonly-logs"` | no |
| `max_session_duration` | `number` | `3600` | no |
| `permissions_boundary_arn` | `string` | `null` | no |
| `tags` | `map(string)` | `{}` | no |
| `log_group_arns` | `list(string)` | `null` (every log group) | no |
| `prometheus_workspace_arns` | `list(string)` | `null` (every workspace) | no |
| `enable_*` | `bool` | see table above | no |

## Outputs

| Name | Description |
|---|---|
| `role_arn` | Paste into the AWS data source in SRE Agent |
| `role_name` | Name of the created role |
| `policy_arn` | ARN of the attached policy |
| `logs_policy_arn` | ARN of the second, log-scoped policy (null unless `log_group_arns` is set) |
| `enabled_services` | What you granted, for confirmation |
