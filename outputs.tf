output "vpc_id" {
  description = "ID of the project VPC."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets used by the ALB and EC2 Auto Scaling Group."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets used by the RDS DB subnet group and EFS mount targets."
  value       = module.vpc.private_subnet_ids
}

output "internet_gateway_id" {
  description = "ID of the VPC Internet Gateway."
  value       = module.vpc.internet_gateway_id
}

output "autoscaling_group_name" {
  description = "Name of the EC2 Auto Scaling Group."
  value       = module.autoscaling.autoscaling_group_name
}

output "autoscaling_security_group_id" {
  description = "ID of the application EC2 security group."
  value       = aws_security_group.ec2.id
}

output "load_balancer_dns_name" {
  description = "DNS name of the public Application Load Balancer."
  value       = module.load_balancer.dns_name
}

output "load_balancer_url" {
  description = "HTTP URL of the public Application Load Balancer."
  value       = "http://${module.load_balancer.dns_name}"
}

output "waf_web_acl_arn" {
  description = "ARN of the regional AWS WAF Web ACL associated with the ALB."
  value       = module.load_balancer.web_acl_arn
}

output "efs_file_system_id" {
  description = "ID of the encrypted shared file system for application attachments."
  value       = module.shared_storage.file_system_id
}

output "rds_endpoint" {
  description = "Private endpoint address of the PostgreSQL database."
  value       = module.rds.endpoint
}

output "rds_port" {
  description = "Port used by the PostgreSQL database."
  value       = module.rds.port
}

output "rds_database_name" {
  description = "Name of the PostgreSQL database used by Comando."
  value       = module.rds.database_name
}

output "rds_master_secret_arn" {
  description = "Secrets Manager ARN containing the RDS-managed master credentials."
  value       = module.rds.master_user_secret_arn
}

output "initial_admin_secret_arn" {
  description = "Secrets Manager ARN for retrieving the generated initial administrator password."
  value       = aws_secretsmanager_secret.initial_admin.arn
}
