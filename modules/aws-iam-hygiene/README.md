# aws-iam-hygiene

The role behind SRE Agent's **AWS IAM hygiene** connector (`aws_iam`). Self-healing's
Security area uses it to deactivate an IAM access key that has not been used for 90 days,
and to put the key back if you undo it.

It is the only place SRE Agent writes to IAM, and the grant is as narrow as that write can
be. It can read who holds a key and when it was last used, and change a key's status. It can
never delete a key, create one, or touch a user, a policy or a login (deleting a key it
deactivated belongs to the separate [`aws-cleanup`](../aws-cleanup) role), and a runbook step can
never name the connector.

Separate from `aws-readonly` on purpose. No read of your account (the capacity, FinOps and
security pages, the inventory sweep, the IAM scan) ever uses this credential, and revoking the
role costs nothing but the key action.

## Usage

```hcl
module "sre_agent_iam_hygiene" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-iam-hygiene?ref=v2.4.0"

  external_id           = "the-value-from-the-settings-page"
  trusted_principal_arn = "arn:aws:iam::111122223333:role/sre-agent-platform"
}

output "role_arn" {
  value = module.sre_agent_iam_hygiene.role_arn
}
```

Then create the connector with that `role_arn`: Settings, Connectors, type **AWS IAM hygiene**,
authentication "assume role"; or the MCP `create_connector` tool with `connector_type`
`aws_iam`; or the Terraform provider's `sreagent_connector` with `connector_type = "aws_iam"`.
The Security area pins the connector (it never picks one by itself).

## What it grants

All on `arn:aws:iam::<account>:user/*`, the users of the account the module is applied in. IAM
is global, so the connector's region is not used, and the connector refuses a key whose user is
in another account.

| Action | Why |
|---|---|
| `iam:GetUser`, `iam:ListAccessKeys`, `iam:GetAccessKeyLastUsed` | Read the user's keys and when the key was last used, before anything is changed. The connector refuses a key the user does not hold. |
| `iam:UpdateAccessKey` | Set the key `Inactive`, or back to `Active` for the undo. Behind `enable_key_changes`. |
| Deny `iam:UpdateAccessKey` on `*` when the user carries the `sre-agent:protect` tag (any value) | A protected user's key is never touched, even if SRE Agent did not check. Exists only where `enable_key_changes` does. |
| `iam:SimulatePrincipalPolicy` (own role ARN only) | The Verify button checks this role against what the app derived, without a write. Behind `enable_verification`. |

This is the same derivation the app shows under Settings, Infrastructure, Show the policy
("IAM hygiene role").

## Inputs

| Name | Type | Default | Required |
|---|---|---|:--:|
| `external_id` | `string` | | yes |
| `trusted_principal_arn` | `string` | | yes |
| `enable_key_changes` | `bool` | `true` | no |
| `enable_verification` | `bool` | `true` | no |
| `protect_tag_key` | `string` | `"sre-agent:protect"` | no |
| `aws_partition` | `string` | `"aws"` | no |
| `role_name` / `policy_name` | `string` | `"sre-agent-iam-hygiene"` | no |
| `max_session_duration` | `number` | `3600` | no |
| `permissions_boundary_arn` | `string` | `null` | no |
| `tags` | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `role_arn` | Paste into the AWS IAM hygiene connector in SRE Agent |
| `role_name` | Name of the created role |
| `policy_arn` | ARN of the attached policy |
| `granted_actions` | The IAM actions the role is allowed on the account's users |
