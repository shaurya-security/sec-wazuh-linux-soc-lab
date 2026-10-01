variable "linux_ami_id" {
  description = "Pinned Amazon Linux 2023 AMI ID"
  type        = string
  default     = "ami-094210f044117049d"
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (must sit inside vpc_cidr)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "owner" {
  description = "Prefix used in resource Name tags."
  type        = string
  default     = "shaurya"
}

variable "userdata_bucket" {
  description = "Existing S3 bucket that holds the bootstrap scripts. Not created by this repo; it must exist before apply."
  type        = string
  default     = "shaurya-terraform-userdata-2026"
}

variable "wazuh_registration_password" {
  description = <<-EOT
    Optional authd enrollment password. Leave as the default empty string
    unless you've explicitly configured authd on the Wazuh manager
    (wazuh.sh) to require a password — it currently does not.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "wazuh_agent_version" {
  description = "Pinned Wazuh agent package version, e.g. 4.14.7-1"
  type        = string
  default     = "4.14.7-1"
}

variable "wazuh_agent_name" {
  description = "Wazuh agent name for the Linux endpoint"
  type        = string
  default     = "linux-endpoint"
}

variable "linux_endpoint_baseline_ami_id" {
  description = "Known-good baseline AMI for the recovery endpoint. The default is the AMI from the recorded run and will not exist in another account; override it."
  type        = string
  default     = "ami-0d58340cece29dd98"
}
