# The ExternalId belongs in the trust policy's condition and nowhere a role listing would show it:
# a role description is readable by anyone who can call iam:GetRole or iam:ListRoles.

# A plan builds the policy documents locally, so no credentials are used or needed.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

variables {
  external_id           = "0123456789abcdef0123"
  trusted_principal_arn = "arn:aws:iam::111122223333:role/sre-agent-platform"
  aws_region            = "us-east-1"
  enable_verification   = false
}

run "role_description_holds_no_external_id" {
  command = plan

  assert {
    condition     = !strcontains(aws_iam_role.this.description, var.external_id) && strcontains(aws_iam_role.this.description, "SRE Agent")
    error_message = "the role description names the ExternalId, or no longer says which product assumes the role"
  }

  assert {
    condition     = strcontains(data.aws_iam_policy_document.trust.json, var.external_id)
    error_message = "the trust policy lost its sts:ExternalId condition"
  }
}
