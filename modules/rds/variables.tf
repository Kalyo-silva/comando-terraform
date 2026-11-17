variable "project_name" {
  description = "Prefix used to name RDS resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the RDS security group is created."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the RDS DB subnet group."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "The RDS DB subnet group must include at least two private subnets."
  }
}

variable "application_security_group_id" {
  description = "Security group ID allowed to connect to PostgreSQL."
  type        = string
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Initial database storage in GiB."
  type        = number
  default     = 20
}

variable "database_name" {
  description = "Name of the initial PostgreSQL database."
  type        = string
  default     = "comando"
}

variable "master_username" {
  description = "Master username for PostgreSQL."
  type        = string
  default     = "comando"
}
