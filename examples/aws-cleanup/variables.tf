variable "region" {
  type        = string
  description = "Region the cleanup connector is configured with. Volumes, snapshots, images, addresses and log groups are regional."
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
