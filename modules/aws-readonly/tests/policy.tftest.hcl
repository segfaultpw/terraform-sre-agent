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
