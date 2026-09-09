output "output_time_ist-----------" {
  description = "Execution timestamp in IST (UTC+5:30)"
  value       = formatdate("YYYY-MM-DD hh:mm:ss", timeadd(timestamp(), "5h30m")) # IST
}

output "wazuh_private_ip----------" {
  value = aws_instance.wazuh.private_ip
}

output "wazuh_public_ip-----------" {
  value = aws_instance.wazuh.public_ip
}

output "wazuh_id------------------" {
  value = aws_instance.wazuh.id
}

output "my_current_public_ip------" {
  value       = chomp(data.http.my_public_ip.response_body)
  description = "The local public IP address fetched dynamically during terraform run."
}

output "linux_endpoint_public_ip--" {
  description = "Public IP address of the Linux endpoint"
  value       = aws_instance.linux_endpoint.public_ip
}

output "linux_endpoint_private_ip-" {
  description = "Private IP address of the Linux endpoint"
  value       = aws_instance.linux_endpoint.private_ip
}

output "linux_endpoint_sg_id------" {
  description = "Security Group ID attached to the Linux endpoint"
  value       = aws_security_group.linux_endpoint_sg.id
}

output "linux_endpoint_instance_id" {
  description = "Instance ID of the Linux endpoint"
  value       = aws_instance.linux_endpoint.id
}

output "linux_endpoint_recovery---" {
  description = "Instance ID of the Linux Recovery"
  value       = aws_instance.linux_endpoint_recovery.id
}
