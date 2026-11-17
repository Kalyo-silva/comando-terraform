variable "project_name" {
  description = "Prefix used to name shared storage resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the EFS security group."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EFS mount targets."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Shared storage must have mount targets in at least two availability zones."
  }
}

variable "application_security_group_id" {
  description = "Security group ID allowed to mount EFS."
  type        = string
}
