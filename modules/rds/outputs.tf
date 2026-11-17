output "endpoint" {
  description = "Private endpoint address of the PostgreSQL database."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port used by the PostgreSQL database."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "Name of the initial PostgreSQL database."
  value       = aws_db_instance.this.db_name
}

output "security_group_id" {
  description = "ID of the RDS security group."
  value       = aws_security_group.database.id
}

output "db_subnet_group_name" {
  description = "Name of the RDS DB subnet group."
  value       = aws_db_subnet_group.this.name
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the RDS-managed master credentials."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
