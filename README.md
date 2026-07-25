# Terraform modules for SRE Agent

The permissions SRE Agent needs, as reviewable Terraform rather than a policy
you paste out of a doc.

Every action in these modules corresponds to a call the product actually makes.
They are generated from the code, not written by hand, which is the point: a
policy that drifts from the code fails as an empty capacity page or an opaque
`AccessDenied`, and neither says which permission was missing.

## Modules

| Module | What it does | Grants |
|---|---|---|
| [`aws-readonly`](modules/aws-readonly) | The role SRE Agent assumes to read your AWS account | Read-only across EC2, CloudWatch, Logs, ECS, Lambda, CloudTrail, optionally X-Ray and Bedrock |
| [`aws-ssm-remediation`](modules/aws-ssm-remediation) | Opt-in command execution for automated remediation | `ssm:SendCommand`, scoped by instance tag and SSM document |
| [`kubernetes-rbac`](modules/kubernetes-rbac) | Read-only cluster access | `get`/`list` on pods, nodes, namespaces, services, deployments, replicasets, jobs, cronjobs, and metrics |

## Start here

You need two values from SRE Agent, both on **Settings → Data sources → AWS**:

- **ExternalId** — generated per organization. Do not invent your own; the
  platform sends the value it generated, and a mismatch denies every
  `AssumeRole`.
- **Trusted principal ARN** — the SRE Agent platform identity. The same for
  every customer, published in the setup guide.

```hcl
module "sre_agent_readonly" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-readonly?ref=v1.0.0"

  external_id           = "the-value-from-the-settings-page"
  trusted_principal_arn = "arn:aws:iam::000000000000:role/sre-agent-platform"
}

output "role_arn" {
  value = module.sre_agent_readonly.role_arn
}
```

Apply, then paste `role_arn` into the AWS data source. Working examples are in
[`examples/`](examples).

## Why a role rather than an access key

SRE Agent supports both, and the modules only build the role.

An access key you paste into a SaaS is a long-lived secret in somebody else's
database that you cannot rotate without their cooperation and cannot audit from
your side. A role you can revoke by deleting it, scope by editing one policy,
and see every use of in your own CloudTrail.

The `sts:ExternalId` condition is what makes it safe: without it, anyone who
learns your role ARN and can persuade the platform to assume it reaches your
account. That is the confused deputy problem, and it is why the ExternalId must
be the generated per-organization value rather than something memorable.

## About the remediation module

`aws-ssm-remediation` grants `ssm:SendCommand`. With the default
`AWS-RunShellScript` document that is **arbitrary command execution** on every
instance it covers.

It is deliberately a separate module and a separate role:

- Revoking remediation should not cost you observability.
- The two want different review cadences.
- An account-wide grant is refused at plan time. You scope it by tag, or you
  explicitly set `i_understand_this_covers_every_instance = true`.

If you want a genuinely bounded grant, publish your own SSM document containing
the specific remediations you are willing to automate and pass it as
`allowed_documents`. The tag scope limits *where*; only the document limits
*what*.

## Versioning

Semantic versioning, tagged per release. Always pin:

```hcl
source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-readonly?ref=v1.0.0"
```

A **minor** bump can add a permission, because the product gained a feature that
needs it. Read [CHANGELOG.md](CHANGELOG.md) before upgrading: with these modules
that is the difference between "new capability" and "new access to your
account", and it should be a decision rather than a `terraform apply`.

A **major** bump changes variables or removes permissions.

## Requirements

| | |
|---|---|
| Terraform | >= 1.5 |
| `hashicorp/aws` | >= 5.0 |
| `hashicorp/kubernetes` | >= 2.24 |

## Verifying what you granted

```bash
terraform output granted            # services the role can read
aws iam get-role-policy --role-name sre-agent-readonly --policy-name sre-agent-readonly
```

If SRE Agent reports no data after applying, check in this order: the ExternalId
matches the settings page, the role ARN is the one you pasted, and the region on
the data source is the region your resources are in.

## Licence

MIT. See [LICENSE](LICENSE).
