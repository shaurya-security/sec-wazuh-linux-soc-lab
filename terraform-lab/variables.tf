variable "linux_ami_id" {
  description = "Pinned Amazon Linux 2023 AMI ID"
  type        = string
  default     = "ami-094210f044117049d"
}


variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "owner" {
  type    = string
  default = "shaurya"
}


variable "userdata_bucket" {
  type    = string
  default = "shaurya-terraform-userdata-2026"
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
  description = "Known-good Amazon Linux AMI used for Linux endpoints"
  type        = string
  default     = "ami-0d58340cece29dd98"
}
