variable "region" {
  type        = string
  description = "Region to create the IAM resources in. IAM is global; this is just the provider region."
  default     = "us-east-1"
}

variable "external_id" {
  type        = string
  description = "ExternalId from the SRE Agent data-source settings page."
}

variable "trusted_principal_arn" {
  type        = string
  description = "SRE Agent platform principal, from the setup guide."
}
