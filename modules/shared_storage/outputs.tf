output "file_system_id" {
  description = "ID of the encrypted EFS file system used for application attachments."
  value       = aws_efs_file_system.this.id
}

output "access_point_id" {
  description = "EFS access point ID configured for the PHP www-data user."
  value       = aws_efs_access_point.attachments.id
}
