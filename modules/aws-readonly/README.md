# aws-readonly

The role SRE Agent assumes to read your AWS account.

Every action maps to a call the product makes. Nothing here can create, modify
or delete anything in your account.

## Usage

```hcl
module "sre_agent_readonly" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-readonly?ref=v1.0.0"

  external_id           = "the-value-from-the-settings-page"
  trusted_principal_arn = "arn:aws:iam::000000000000:role/sre-agent-platform"
}
```

## What each toggle buys you

| Variable | Default | Feature it powers | Without it |
|---|---|---|---|
| `enable_ec2` | `true` | Capacity planning, FinOps waste detectors | No instances, volumes, EIPs, snapshots or AMIs. The capacity and FinOps pages read as empty. |
| `enable_cloudwatch` | `true` | SLIs, utilization, alarm correlation | No metrics, so nothing is ever "idle" or "oversized" |
| `enable_logs` | `true` | Log search during investigations | Investigations cannot read logs |
| `enable_ecs` | `true` | ECS services as workloads | ECS services absent from capacity |
| `enable_lambda` | `true` | Lambda functions as workloads | Functions absent from capacity |
| `enable_cloudtrail` | `true` | "Who changed what" during an investigation | No change correlation |
| `enable_xray` | `false` | Trace summaries for latency work | No traces |
| `enable_bedrock` | `false` | Bedrock as *your* AI provider | Nothing, unless you configured Bedrock |

Turning one off is safe. The feature degrades to "no data" rather than erroring,
which is worth knowing: **an empty page and a missing permission look the
same**, so if something reads as empty, check the policy before assuming there
is nothing to report.

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
| `enable_*` | `bool` | see above | no |

## Outputs

| Name | Description |
|---|---|
| `role_arn` | Paste into the AWS data source in SRE Agent |
| `role_name` | Name of the created role |
| `policy_arn` | ARN of the attached policy |
| `enabled_services` | What you granted, for confirmation |
