# kubernetes-rbac

Read-only cluster access for SRE Agent: a ServiceAccount, a ClusterRole limited
to what the product reads, and a token for the connector.

`get` and `list` only. The client can issue writes, but no code path does, so
granting them would be authority nobody uses.

## Usage

```hcl
module "sre_agent_rbac" {
  source = "github.com/segfaultpw/terraform-sre-agent//modules/kubernetes-rbac?ref=v2.0.1"

  namespace = "kube-system"
}

output "token" {
  value     = module.sre_agent_rbac.token
  sensitive = true
}
```

```bash
terraform output -raw token   # paste into the Kubernetes connector
```

## What it reads

| API group | Resources |
|---|---|
| core (`""`) | `pods`, `nodes`, `namespaces`, `services` |
| `apps` | `deployments`, `replicasets` |
| `batch` | `jobs`, `cronjobs` |
| `metrics.k8s.io` | `pods`, `nodes` (if `enable_metrics`) |
| core (`""`) | `events` (if `enable_events`) |

## Two things worth deciding rather than defaulting

**`enable_metrics`** requires metrics-server. Without it the capacity page shows
requests but no usage, which reads as "nothing is over-provisioned" rather than
as missing data. Leave it on unless you know metrics-server is absent.

**`enable_events`** is the most useful signal during an investigation
(OOMKills, failed scheduling, image pull errors), but event messages can carry
application detail. Separately controllable for that reason.

## About the token

`create_token = true` makes a long-lived ServiceAccount token Secret. Kubernetes
1.24+ no longer mints one automatically, and SRE Agent connects from outside the
cluster so it cannot refresh a projected volume token.

It grants read access to the whole cluster. Do not commit it or echo it in CI.
If you have your own short-lived token rotation, set `create_token = false` and
supply the token yourself.

## Inputs

| Name | Type | Default |
|---|---|---|
| `namespace` | `string` | `"kube-system"` |
| `service_account_name` | `string` | `"sre-agent"` |
| `cluster_role_name` | `string` | `"sre-agent-readonly"` |
| `cluster_role_binding_name` | `string` | `"sre-agent-readonly"` |
| `enable_metrics` | `bool` | `true` |
| `enable_events` | `bool` | `true` |
| `create_token` | `bool` | `true` |
| `labels` | `map(string)` | `{"app.kubernetes.io/name" = "sre-agent"}` |

## Outputs

| Name | Description |
|---|---|
| `token` | Bearer token (sensitive) |
| `cluster_ca_certificate` | CA cert for TLS verification (sensitive) |
| `service_account_name`, `namespace`, `cluster_role_name` | For confirmation |
