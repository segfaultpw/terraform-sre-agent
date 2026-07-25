# Changelog

Semantic versioning. **Read this before upgrading**: with these modules a minor
bump can widen access to your account, and that should be a decision rather
than a `terraform apply`.

- **major** — variables changed, or permissions removed
- **minor** — a permission added, because the product gained a feature needing it
- **patch** — documentation, validation, formatting; no change to what is granted

## [Unreleased]

### Added
- `aws-readonly`: the role SRE Agent assumes to read an AWS account, covering
  EC2, CloudWatch, CloudWatch Logs, ECS, Lambda and CloudTrail by default, with
  X-Ray and Bedrock opt-in.
- `aws-ssm-remediation`: opt-in `ssm:SendCommand`, scoped by instance tag and
  SSM document, refusing an unscoped grant at plan time.
- `kubernetes-rbac`: ServiceAccount, read-only ClusterRole and binding, with
  optional metrics and events, plus a long-lived token for Kubernetes 1.24+.
