locals {
  owner    = var.owner
  vpc_name = "${local.owner}-vpc"
  igw_name = "${local.owner}-igw"

  subnet_name        = "${local.owner}-subnet"
  public_subnet_name = "${local.subnet_name}-public"
  #  private_subnet_name = "${local.subnet_name}-private"

  rtb_name        = "${local.owner}-rtb"
  public_rtb_name = "${local.rtb_name}-public"
  #  private_rtb_name = "${local.rtb_name}-private"

  sg_name        = "${local.owner}-sg"
  wazuh_sg_name  = "${local.sg_name}-wazuh"
  ec2_name       = "${local.owner}-instance"
  wazuh_ec2_name = "${local.ec2_name}-wazuh"

  linux_endpoint_sg_name = "${local.sg_name}-linux-endpoint"

  # Operator workstation public IP, allow-listed for the dashboard (443) and SSH (22).
  operator_cidr = "${chomp(data.http.my_public_ip.response_body)}/32"
}
