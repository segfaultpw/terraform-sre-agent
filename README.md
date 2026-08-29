# Terraform modules for SRE Agent

The permissions SRE Agent needs, as reviewable Terraform rather than a policy
you paste out of a doc.

The read policy covers the **service-wide read surface** for workloads,
observability and tagging. That is deliberately wider than the exact calls the product
makes today.

That is a trade, so it is worth stating plainly. A policy pinned to today's call
list has to be re-applied every time a feature ships, and when it is stale the
failure is silent: a missing permission and "there is nothing to report" render
identically in this product. Describe/list access to compute and telemetry is
also the grant most organisations already model as low risk. If you would rather
grant only what is used right now, every service is individually toggleable.

Nothing in the read modules can create, modify or delete.

## Modules

| Module | What it does | Grants |
|---|---|---|
| [`aws-readonly`](modules/aws-readonly) | The role SRE Agent assumes to read your AWS account | Broad control-plane read across compute, storage, databases, streaming, networking, observability, cost and tagging. Bedrock opt-in. |
| [`aws-ssm-remediation`](modules/aws-ssm-remediation) | Opt-in command execution for automated remediation | `ssm:SendCommand`, scoped by instance tag and SSM document |
| [`kubernetes-rbac`](modules/kubernetes-rbac) | Read-only cluster access | `get`/`list` on pods, nodes, namespaces, services, deployments, replicasets, jobs, cronjobs, plus metrics and events |

## Start here

Both values you need are shown on the AWS data-source form in SRE Agent:
**Settings → Data sources → add or edit an AWS source → auth type "assume
role"**.

- **ExternalId**: generated for your organization. Do not invent your own: the
  platform sends the value it issued, and a mismatch denies every `AssumeRole`.
- **Principal to trust**: the identity that assumes your role. The same for
  every customer.

Neither is a secret, and the ARNs in this repository are samples. The principal
grants nothing on its own, because every request must also carry your ExternalId,
which is the whole point of the condition.

```hcl
module "sre_agent_readonly" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-readonly?ref=v2.2.0"

  external_id           = "the-value-from-the-settings-page"
  trusted_principal_arn = "arn:aws:iam::111122223333:role/sre-agent-platform"
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
source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-readonly?ref=v2.2.0"
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

## EKS needs both modules

The compute group (`enable_compute`) grants the AWS-side EKS view: clusters,
node groups, versions. It does
**not** let SRE Agent see what runs inside the cluster. EKS authorises that
separately through the cluster's own RBAC. For workloads, pods and utilization,
apply `kubernetes-rbac` against the cluster as well.

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
