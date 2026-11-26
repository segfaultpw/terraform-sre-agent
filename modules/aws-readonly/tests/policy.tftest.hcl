# SRE Agent no longer reads WAF or API Gateway, so the rendered policy must hold none of
# their actions and no deny that guarded an API Gateway allow. The two retired switches
# stay as deprecated no-ops: setting them must neither fail a plan nor change the policy,
# and setting one to true must raise its deprecation warning.

# A plan builds the policy document locally, so no credentials are used or needed.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

# The policy document reads the role's ARN, and a plan defers a data source that depends
# on a resource to be created, so these runs apply with the three resources stubbed. The
# document itself is rendered by the provider for real.
override_resource {
  target = aws_iam_role.this
  values = {
    name = "sre-agent-readonly"
    arn  = "arn:aws:iam::123456789012:role/sre-agent-readonly"
  }
}

override_resource {
  target = aws_iam_policy.this
  values = {
    arn = "arn:aws:iam::123456789012:policy/sre-agent-readonly"
  }
}

override_resource {
  target = aws_iam_role_policy_attachment.this
  values = {}
}

override_resource {
  target = aws_iam_policy.logs_scoped
  values = {
    arn = "arn:aws:iam::123456789012:policy/sre-agent-readonly-logs"
  }
}

override_resource {
  target = aws_iam_role_policy_attachment.logs_scoped
  values = {}
}

variables {
  external_id           = "0123456789abcdef0123"
  trusted_principal_arn = "arn:aws:iam::111122223333:role/sre-agent-platform"
  enable_verification   = false
}

run "grants_no_waf_or_api_gateway_action" {
  command = apply

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if length([
        for a in flatten([s.Action]) : a
        if startswith(a, "wafv2:") || startswith(a, "apigateway:") || startswith(a, "waf:") || startswith(a, "waf-regional:")
      ]) > 0
    ]) == 0
    error_message = "the policy still grants a WAF or API Gateway action"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if try(s.Sid, "") == "NoApiKeyValues" || s.Effect == "Deny"
    ]) == 0
    error_message = "the policy still carries the API key deny that guarded the API Gateway allow"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if contains(["Waf", "WafRead", "Apigateway", "ApiGatewayRead", "EdgeInventory"], try(s.Sid, ""))
    ]) == 0
    error_message = "a statement of the removed WAF or API Gateway groups is still rendered"
  }
}

run "deprecated_switches_set_to_true_change_nothing" {
  command = apply

  variables {
    enable_waf_read        = true
    enable_apigateway_read = true
  }

  expect_failures = [
    check.deprecated_enable_waf_read,
    check.deprecated_enable_apigateway_read,
  ]

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if length([
        for a in flatten([s.Action]) : a
        if startswith(a, "wafv2:") || startswith(a, "apigateway:")
      ]) > 0
    ]) == 0
    error_message = "a deprecated switch set to true granted an action"
  }
}

run "deprecated_switches_left_alone_raise_no_warning" {
  command = apply

  assert {
    condition     = var.enable_waf_read == false && var.enable_apigateway_read == false
    error_message = "the deprecated switches must default to false"
  }
}

# The IAM scan reads an account in a few calls with iam:GetAccountAuthorizationDetails, and
# Capacity and FinOps read CloudWatch with cloudwatch:GetMetricData. The module needs no new
# action for either, because its identity group already grants iam:Get* and its observability
# group cloudwatch:Get*; this pins that the defaults keep granting them.
run "identity_read_covers_the_bulk_iam_read" {
  command = apply

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if contains(flatten([s.Action]), "iam:Get*") || contains(flatten([s.Action]), "iam:GetAccountAuthorizationDetails")
    ]) > 0
    error_message = "no statement grants iam:Get*, which covers iam:GetAccountAuthorizationDetails"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if contains(flatten([s.Action]), "cloudwatch:Get*") || contains(flatten([s.Action]), "cloudwatch:GetMetricData")
    ]) > 0
    error_message = "no statement grants cloudwatch:Get*, which covers cloudwatch:GetMetricData"
  }
}

# The ExternalId is the confused-deputy protection: it belongs in the trust policy's condition and
# nowhere a role listing, CloudTrail or an inventory tool would show it. A role description is
# readable by anyone who can call iam:GetRole or iam:ListRoles.
run "role_description_holds_no_external_id" {
  command = apply

  assert {
    condition     = !strcontains(aws_iam_role.this.description, var.external_id) && aws_iam_role.this.description != ""
    error_message = "the role description names the ExternalId, or is empty"
  }

  assert {
    condition     = strcontains(aws_iam_role.this.description, "SRE Agent")
    error_message = "the role description no longer says which product assumes the role"
  }

  assert {
    condition     = aws_iam_role.this.tags == null || length([for k, v in aws_iam_role.this.tags : k if strcontains(v, var.external_id)]) == 0
    error_message = "a tag carries the ExternalId"
  }

  assert {
    condition     = strcontains(data.aws_iam_policy_document.trust.json, var.external_id)
    error_message = "the trust policy lost its sts:ExternalId condition"
  }
}

# --- log_group_arns ---------------------------------------------------------------------------
# Unset, nothing changes: the Logs actions sit in the Observability statement on "*" and the second
# policy and its attachment do not exist.
run "logs_are_account_wide_by_default" {
  command = apply

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if s.Sid == "Observability" && contains(flatten([s.Action]), "logs:StartQuery") && contains(flatten([s.Action]), "logs:Describe*") && flatten([s.Resource]) == ["*"]
    ]) == 1
    error_message = "unset log_group_arns must keep the Logs actions in the Observability statement on *"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if contains(["LogsScoped", "LogsAccountWide", "Prometheus"], s.Sid)
    ]) == 0
    error_message = "unset log_group_arns and enable_prometheus must render none of the new statements"
  }

  assert {
    condition     = length(aws_iam_policy.logs_scoped) == 0 && length(aws_iam_role_policy_attachment.logs_scoped) == 0 && output.logs_policy_arn == null
    error_message = "unset log_group_arns must create no second policy"
  }
}

run "log_group_arns_scope_the_log_reads_in_a_second_policy" {
  command = apply

  variables {
    log_group_arns = [
      "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/checkout",
      "arn:aws:logs:us-east-1:123456789012:log-group:/prod/*:*",
    ]
  }

  # The main policy holds no logs: action at all.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if length([for a in flatten([s.Action]) : a if startswith(a, "logs:")]) > 0
    ]) == 0
    error_message = "the main policy still grants a logs: action while log_group_arns is set"
  }

  assert {
    condition = jsonencode([
      for s in jsondecode(data.aws_iam_policy_document.logs_scoped[0].json).Statement :
      sort(flatten([s.Resource]))
      if s.Sid == "LogsScoped"
      ]) == jsonencode([[
        "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/checkout",
        "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/checkout:*",
        "arn:aws:logs:us-east-1:123456789012:log-group:/prod/*",
        "arn:aws:logs:us-east-1:123456789012:log-group:/prod/*:*",
    ]])
    error_message = "LogsScoped must name each group and its streams, once, with a trailing :* folded away"
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(data.aws_iam_policy_document.logs_scoped[0].json).Statement : s.Action if s.Sid == "LogsAccountWide"
    ])) == toset(["logs:DescribeLogGroups", "logs:StopQuery"])
    error_message = "LogsAccountWide must hold exactly the two actions the product calls that take no resource"
  }

  # The seven Logs actions the product calls are all granted, scoped or not.
  assert {
    condition = alltrue([
      for need in ["logs:FilterLogEvents", "logs:StartQuery", "logs:Get*", "logs:Describe*"] :
      contains(flatten([for s in jsondecode(data.aws_iam_policy_document.logs_scoped[0].json).Statement : s.Action if s.Sid == "LogsScoped"]), need)
    ])
    error_message = "LogsScoped lost an action the product calls (GetQueryResults, GetLogEvents and GetLogGroupFields ride on Get*)"
  }

  assert {
    condition     = length(aws_iam_policy.logs_scoped) == 1 && length(aws_iam_role_policy_attachment.logs_scoped) == 1 && output.logs_policy_arn == "arn:aws:iam::123456789012:policy/sre-agent-readonly-logs"
    error_message = "log_group_arns must create and attach the second policy and output its ARN"
  }

  # Everything else the observability group granted is untouched.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if s.Sid == "Observability" && contains(flatten([s.Action]), "cloudwatch:Get*") && contains(flatten([s.Action]), "xray:Get*") && contains(flatten([s.Action]), "cloudtrail:LookupEvents")
    ]) == 1
    error_message = "scoping the logs must not touch the other observability actions"
  }
}

run "log_group_arns_do_nothing_when_observability_is_off" {
  command = apply

  variables {
    enable_observability = false
    log_group_arns       = ["arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/checkout"]
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if length([for a in flatten([s.Action]) : a if startswith(a, "logs:")]) > 0
    ]) == 0 && length(aws_iam_policy.logs_scoped) == 0
    error_message = "with enable_observability false no logs: action may be granted and no second policy created"
  }
}

# The second policy is refused by AWS above 6,144 characters without whitespace. The validation's own
# arithmetic (294 fixed + 2 * length + 8 per ARN <= 6,144) is pinned against the policy AWS would see:
# ten ARNs of 288 or 289 characters (five and five) are exactly 6,144 characters, one character more is refused.
run "the_second_policy_at_the_size_limit_is_accepted_and_fits" {
  command = apply

  variables {
    log_group_arns = [for i in range(10) : "arn:aws:logs:us-east-1:123456789012:log-group:${join("", [for k in range(i < 5 ? 241 : 242) : "x"])}${i}"]
  }

  assert {
    condition     = length(data.aws_iam_policy_document.logs_scoped[0].minified_json) == 6144
    error_message = "ten ARNs of 288 and 289 characters must render a 6,144 character policy, the limit AWS enforces"
  }
}

run "one_character_over_the_size_limit_is_refused" {
  command = plan

  variables {
    log_group_arns = [for i in range(10) : "arn:aws:logs:us-east-1:123456789012:log-group:${join("", [for k in range(i < 5 ? 241 : (i == 5 ? 243 : 242)) : "x"])}${i}"]
  }

  expect_failures = [var.log_group_arns]
}

run "an_empty_log_group_list_is_refused" {
  command = plan

  variables {
    log_group_arns = []
  }

  expect_failures = [var.log_group_arns]
}

run "a_log_group_name_that_is_not_an_arn_is_refused" {
  command = plan

  variables {
    log_group_arns = ["/aws/lambda/checkout"]
  }

  expect_failures = [var.log_group_arns]
}

# --- enable_prometheus ------------------------------------------------------------------------
run "prometheus_reads_every_workspace_when_enabled" {
  command = apply

  variables {
    enable_prometheus = true
  }

  assert {
    condition = jsonencode([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      [sort(flatten([s.Action])), flatten([s.Resource])] if s.Sid == "Prometheus"
    ]) == jsonencode([[["aps:GetLabels", "aps:GetMetricMetadata", "aps:GetSeries", "aps:ListRules", "aps:QueryMetrics"], ["*"]]])
    error_message = "the Prometheus group must be the five read actions on *"
  }

  assert {
    condition     = contains(output.enabled_services, "prometheus")
    error_message = "enabled_services must name the prometheus group"
  }
}

run "prometheus_can_be_limited_to_workspaces" {
  command = apply

  variables {
    enable_prometheus         = true
    prometheus_workspace_arns = ["arn:aws:aps:us-east-1:123456789012:workspace/ws-0123abcd"]
  }

  assert {
    condition = jsonencode([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      flatten([s.Resource]) if s.Sid == "Prometheus"
    ]) == jsonencode([["arn:aws:aps:us-east-1:123456789012:workspace/ws-0123abcd"]])
    error_message = "the Prometheus group must be limited to the listed workspace"
  }
}

run "a_workspace_arn_that_is_not_one_is_refused" {
  command = plan

  variables {
    enable_prometheus         = true
    prometheus_workspace_arns = ["ws-0123abcd"]
  }

  expect_failures = [var.prometheus_workspace_arns]
}

run "prometheus_workspace_arns_alone_grant_nothing" {
  command = apply

  variables {
    prometheus_workspace_arns = ["arn:aws:aps:us-east-1:123456789012:workspace/ws-0123abcd"]
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readonly.json).Statement :
      s if length([for a in flatten([s.Action]) : a if startswith(a, "aps:")]) > 0
    ]) == 0
    error_message = "without enable_prometheus no aps: action may be granted"
  }
}
