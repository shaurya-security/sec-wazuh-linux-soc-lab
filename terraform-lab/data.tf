########################################
# Amazon Linux 2023 lookup
#
# Not referenced by any resource: var.linux_ami_id is pinned in variables.tf.
# Kept for finding a newer AL2023 AMI to pin.
########################################

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name = "name"

    values = [
      "al2023-ami-20*-kernel-*-x86_64"
    ]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

########################################
# Operator public IP (allow-list source)
########################################

data "http" "my_public_ip" {
  url = "https://ipv4.icanhazip.com"
}
