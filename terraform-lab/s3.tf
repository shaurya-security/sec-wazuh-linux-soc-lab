locals {
  userdata_scripts = [
    "common.sh",
    "wazuh.sh",
    "linux-endpoint.sh",
    "simulate_soc_chain.sh",
    "userdata-logs.sh",
    "recovery-assessment.sh",
  ]
}

# Upload userdata scripts and track file changes via MD5 hash
resource "aws_s3_object" "userdata_scripts" {
  for_each = toset(local.userdata_scripts)

  bucket = var.userdata_bucket
  key    = each.value
  source = "${path.module}/userdata/${each.value}"
  etag   = filemd5("${path.module}/userdata/${each.value}")
}
