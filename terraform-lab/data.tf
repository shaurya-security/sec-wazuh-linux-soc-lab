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


data "http" "my_public_ip" {
  url = "https://ipv4.icanhazip.com"

}


