resource "aws_instance" "wazuh" {
  ami                         = var.linux_ami_id
  instance_type               = "m7i-flex.large"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.wazuh_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  user_data_replace_on_change = true

  depends_on = [
    time_sleep.wait_for_iam,
    aws_s3_object.userdata_scripts["common.sh"],
    aws_s3_object.userdata_scripts["recovery-assessment.sh"],
    aws_s3_object.userdata_scripts["wazuh.sh"]
  ]

  user_data = templatefile("${path.module}/userdata/wazuh.sh.tpl", {
    s3_bucket   = var.userdata_bucket
    script_name = "wazuh.sh"
    common_hash = filemd5("${path.module}/userdata/common.sh")
    script_hash = filemd5("${path.module}/userdata/wazuh.sh")
    timezone    = "Asia/Kolkata"
  })
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }
  tags = { Name = local.wazuh_ec2_name }
}

########################################
# Linux Endpoint EC2 Instance
########################################
resource "aws_instance" "linux_endpoint" {
  ami                         = var.linux_ami_id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.linux_endpoint_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  user_data_replace_on_change = true

  depends_on = [
    time_sleep.wait_for_iam,
    aws_s3_object.userdata_scripts["common.sh"],
    aws_s3_object.userdata_scripts["linux-endpoint.sh"],
    aws_s3_object.userdata_scripts["recovery-assessment.sh"],
    aws_s3_object.userdata_scripts["simulate_soc_chain.sh"],
    aws_instance.wazuh
  ]

  # User data now runs common.sh AND linux-endpoint.sh, with the Wazuh
  # manager address, pinned agent version, and (optional, currently unused)
  # enrollment password supplied explicitly by Terraform — the same
  # architectural pattern used for the Windows endpoint's WazuhManagerIP
  # parameter. wazuh_registration_password defaults to "" because wazuh.sh
  # doesn't configure authd to require one.
  user_data = templatefile("${path.module}/userdata/linux-endpoint.sh.tpl", {
    s3_bucket                   = var.userdata_bucket
    common_hash                 = filemd5("${path.module}/userdata/common.sh")
    linux_endpoint_hash         = filemd5("${path.module}/userdata/linux-endpoint.sh")
    wazuh_manager_ip            = aws_instance.wazuh.private_ip
    wazuh_registration_password = var.wazuh_registration_password
    wazuh_agent_version         = var.wazuh_agent_version
    wazuh_agent_name            = var.wazuh_agent_name
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }
  tags = {
    Name = "${local.ec2_name}-linux-endpoint"
  }
}


########################################
# Linux Endpoint - Recovery Replacement
# Created from known-good pre-compromise AMI
########################################
resource "aws_instance" "linux_endpoint_recovery" {
  ami                    = var.linux_endpoint_baseline_ami_id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.linux_endpoint_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  depends_on = [
    aws_instance.wazuh
  ]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name     = "${local.ec2_name}-linux-endpoint-recovery"
    AMI      = "soc-lab-linux-endpoint-baseline-20260909-121429"
    AMI_ID   = var.linux_endpoint_baseline_ami_id
    Recovery = "true"
  }
}
