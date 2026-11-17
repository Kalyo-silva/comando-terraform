output "autoscaling_group_name" {
  description = "Name of the EC2 Auto Scaling Group."
  value       = aws_autoscaling_group.instances.name
}

output "launch_template_id" {
  description = "ID of the launch template."
  value       = aws_launch_template.instances.id
}

output "security_group_id" {
  description = "ID of the instance security group."
  value       = var.instance_security_group_id
}

output "ubuntu_ami_id" {
  description = "Ubuntu Server 22.04 LTS AMI selected for the launch template."
  value       = data.aws_ami.ubuntu.id
}
