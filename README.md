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
| [`aws-readonly`](modules/aws-readonly) | The role SRE Agent assumes to read your AWS account | Broad control-plane read across compute, storage, databases, streaming, networking, observability, cost, tagging and identity (IAM inventory, credential report, Identity Center; the compliance evidence rides these). Bedrock opt-in. |
| [`aws-ssm-remediation`](modules/aws-ssm-remediation) | Opt-in command execution for automated remediation | `ssm:SendCommand`, scoped by instance tag and SSM document |
| [`aws-iam-hygiene`](modules/aws-iam-hygiene) | The role behind the AWS IAM hygiene connector (`aws_iam`), so self-healing can deactivate an access key unused for 90 days | `iam:GetUser`, `iam:ListAccessKeys`, `iam:GetAccessKeyLastUsed` and `iam:UpdateAccessKey` on the account's users. Never deletes or creates a key. |
| [`aws-cleanup`](modules/aws-cleanup) | The role behind the AWS cleanup connector (`aws_cleanup`), so self-healing can delete what scans found unused once deletions are on. Deleting the role stops every deletion | Deletes of IAM access keys and login profiles, EBS volumes, snapshots and images, Elastic IP releases and log retention, each behind its own switch, scoped to resource types, with a Deny on anything tagged `sre-agent:protect`. |
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
  source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-readonly?ref=v3.0.0"

  external_id           = "the-value-from-the-settings-page"
  trusted_principal_arn = "arn:aws:iam::111122223333:role/sre-agent-platform"
}

output "role_arn" {
  value = module.sre_agent_readonly.role_arn
}
```

Apply, then paste `role_arn` into the AWS data source. Working examples are in
[`examples/`](examples).

## The IAM hygiene role

Self-healing's Security area can deactivate an IAM access key that has not been used for 90
days. It does that through a connector of its own, type **AWS IAM hygiene**, with a role of its
own, which [`aws-iam-hygiene`](modules/aws-iam-hygiene) builds. Neither `aws-readonly` nor
`aws-ssm-remediation` is enough for it, and nothing that reads your account ever uses it. See
[`examples/aws-iam-hygiene`](examples/aws-iam-hygiene).

## The cleanup role

Self-healing's deletions (an access key it deactivated, an unattached volume after a snapshot, an
unassociated Elastic IP, an old snapshot or image while a Recycle Bin rule keeps it, a log
retention you chose) go through a connector of its own, type **AWS cleanup (deletions)**, with a
role of its own, which [`aws-cleanup`](modules/aws-cleanup) builds. Deleting that role stops every
deletion, and anything tagged `sre-agent:protect` is refused by AWS itself. See
[`examples/aws-cleanup`](examples/aws-cleanup).

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
source = "github.com/segfaultpw/terraform-sre-agent//modules/aws-readonly?ref=v3.0.0"
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

## EKS: what each module lets SRE Agent see

`aws-readonly` alone is enough for SRE Agent to find your EKS clusters and the
workloads running in them. The compute group (`enable_compute`) grants
`eks:ListClusters` and `eks:DescribeCluster`, and the observability group
(`enable_observability`) grants `cloudwatch:ListMetrics`, which is how the
product reads each workload's name, namespace and cluster from Container
Insights' metric dimensions. No kubeconfig is involved. This needs Container
Insights enabled on the cluster (the CloudWatch Observability add-on with
`containerInsights` on); a cluster without it is still listed, with no
workloads under it.

`kubernetes-rbac` is for reading the cluster's own API, which EKS authorises
separately through the cluster's RBAC: the security findings scan and live
Kubernetes resources. Apply it against the cluster as well if you want those.

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
