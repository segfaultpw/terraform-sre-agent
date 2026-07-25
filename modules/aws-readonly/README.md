# aws-readonly

The role SRE Agent assumes to read your AWS account.

Covers the service-wide read surface for workloads, observability and tagging.
Nothing here can create, modify or delete anything in your account.

## Usage

```hcl
module "sre_agent_readonly" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-readonly?ref=v2.0.1"

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
| `enable_ec2` | `true` | Capacity planning and every FinOps waste detector. Without it those pages read as empty. |
| `enable_autoscaling` | `true` | ASGs decide how many instances a workload has; without them capacity is a snapshot, not a trend. |
| `enable_ecs` | `true` | ECS clusters, services and tasks as workloads. |
| `enable_eks` | `true` | EKS clusters and node groups (AWS-side only, see below). |
| `enable_lambda` | `true` | Lambda functions as workloads. |
| `enable_load_balancing` | `true` | Load balancers and target groups: where "the service is down" is usually first visible. |
| `enable_databases` | `true` | RDS and ElastiCache metadata and configuration. No data-plane access exists in these actions. |
| `enable_cloudwatch` | `true` | SLIs, utilization, alarm correlation. Without it nothing is ever "idle" or "oversized". |
| `enable_logs` | `true` | Log search during investigations, including Insights. |
| `enable_cloudtrail` | `true` | "Who changed what" during an investigation. |
| `enable_xray` | `true` | Trace summaries for latency work. |
| `enable_tagging` | `true` | Resolves ownership across every service at once. Without it, ownership is derived service by service and misses anything neither side knows about. |
| `enable_bedrock` | `false` | Only if you point SRE Agent's AI provider at Bedrock in *your* account. The one block that is not read-only: `InvokeModel` bills you directly. |

### EKS needs the Kubernetes module too

`enable_eks` grants the AWS-side view only. Reading what runs inside the cluster
is authorised separately by the cluster's own RBAC, so apply
`kubernetes-rbac` as well if you want pods, workloads and utilization.

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
