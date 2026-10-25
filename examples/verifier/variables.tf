variable "region" {
  type        = string
  description = "The Region to run the verifier in."
  default     = "us-east-1"
}

variable "sre_agent_url" {
  type        = string
  description = "Your SRE Agent origin, such as https://sre.example.com."
}

variable "api_key_secret_arn" {
  type        = string
  description = "The full ARN, with its six-character suffix, of the Secrets Manager secret that holds the verifier:poll API key (the plain key as the value), in the Region above."
}

variable "images" {
  type        = map(string)
  description = "Runtime to published verifier image, pinned by digest."
}
