# aws-ssm-remediation

Opt-in command execution, so SRE Agent can act on an incident rather than only
describe it.

> **This grants `ssm:SendCommand`.** With the default `AWS-RunShellScript`
> document that is arbitrary command execution on every instance it covers.
> Treat applying this as granting shell, because that is what it is.

Separate from `aws-readonly` on purpose: revoking remediation should not cost
you observability, and the two want different review cadences.

## Usage

```hcl
module "sre_agent_remediation" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-ssm-remediation?ref=v2.0.1"

  external_id           = "the-value-from-the-settings-page"
  trusted_principal_arn = "arn:aws:iam::111122223333:role/sre-agent-platform"
  aws_region            = "us-east-1"

  target_instance_tags = {
    "sre-agent-remediation" = ["true"]
  }
}
```

Then tag the instances you are willing to have touched:

```bash
aws ec2 create-tags --resources i-0123456789abcdef0 \
  --tags Key=sre-agent-remediation,Value=true
```

## Two axes of scope, and only one of them limits *what*

`target_instance_tags` limits **where** a command can run. An instance must
carry every tag listed.

`allowed_documents` limits **what** can run, and only if you replace the
default. `AWS-RunShellScript` accepts any shell, so tag scoping alone gives you
"arbitrary commands, on these hosts". For a genuinely bounded grant, publish
your own document containing the specific remediations you are willing to
automate:

```hcl
allowed_documents = ["MyOrg-RestartAppServer", "MyOrg-RotateLogs"]
```

An empty `target_instance_tags` covers every SSM-managed instance in the
account and is **refused at plan time** unless you also set
`i_understand_this_covers_every_instance = true`. Forgetting to scope should
fail, not succeed quietly.

## What it grants

| Action | Why |
|---|---|
| `ssm:SendCommand` | Run the remediation. Scoped to tagged instances and allowed documents. |
| `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations`, `ssm:ListCommands` | Read back what happened. Starting work it cannot report on is worse than not starting. |
| `ssm:DescribeInstanceInformation` | Tell "instance offline" from "command failed", which are different incidents. |
| `iam:SimulatePrincipalPolicy` (own role ARN only) | The Verify button checks this role against what the app derived, without a write. Behind `enable_verification`. |

## Inputs

| Name | Type | Default | Required |
|---|---|---|:--:|
| `external_id` | `string` | | yes |
| `trusted_principal_arn` | `string` | | yes |
| `aws_region` | `string` | | yes |
| `target_instance_tags` | `map(list(string))` | `{"sre-agent-remediation" = ["true"]}` | no |
| `allowed_documents` | `list(string)` | `["AWS-RunShellScript"]` | no |
| `i_understand_this_covers_every_instance` | `bool` | `false` | no |
| `aws_partition` | `string` | `"aws"` | no |
| `role_name` / `policy_name` | `string` | `"sre-agent-remediation"` | no |
| `max_session_duration` | `number` | `3600` | no |
| `enable_verification` | `bool` | `true` | no |
| `permissions_boundary_arn` | `string` | `null` | no |
| `tags` | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `role_arn` | Paste into the remediation connector in SRE Agent |
| `role_name` | Name of the created role |
| `policy_arn` | ARN of the attached policy |
| `scoped_to_tags` | The tags an instance must carry. Empty means everything. |
