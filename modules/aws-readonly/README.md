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
| `enable_identity_read` | `true` | The IAM inventory behind the Security page's findings, CloudTrail principal resolution, and (since v2.3) the compliance posture scan's credential report and Identity Center reads. Names, policies, key ages, MFA facts and last-used, never credentials. |
| `enable_inventory` | `true` | SSM inventory, Secrets Manager metadata (never values), ECR and Step Functions: existence of things the other groups do not name. |
| `enable_verification` | `true` | `iam:SimulatePrincipalPolicy`, scoped to this role's own ARN: the Verify button answers with evidence instead of "unverified". |
| `enable_bedrock` | `false` | Only if you point SRE Agent's AI provider at Bedrock in *your* account. The one block that is not read-only: `InvokeModel` bills you directly. |

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

## Inputs

| Name | Type | Default | Required |
|---|---|---|:--:|
| `external_id` | `string` | | yes |
| `trusted_principal_arn` | `string` | | yes |
| `role_name` | `string` | `"sre-agent-readonly"` | no |
| `policy_name` | `string` | `"sre-agent-readonly"` | no |
| `max_session_duration` | `number` | `3600` | no |
| `permissions_boundary_arn` | `string` | `null` | no |
| `tags` | `map(string)` | `{}` | no |
| `enable_*` | `bool` | see table above | no |

## Outputs

| Name | Description |
|---|---|
| `role_arn` | Paste into the AWS data source in SRE Agent |
| `role_name` | Name of the created role |
| `policy_arn` | ARN of the attached policy |
| `enabled_services` | What you granted, for confirmation |
