variable "project_name" {
  description = "Prefix used to name EC2 Auto Scaling resources."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs used by the Auto Scaling Group."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "The Auto Scaling Group must span at least two public subnets."
  }
}

variable "instance_type" {
  description = "EC2 instance type used by the launch template."
  type        = string
  default     = "t2.medium"
}

variable "min_size" {
  description = "Minimum number of instances in the Auto Scaling Group."
  type        = number
  default     = 1
}

variable "desired_capacity" {
  description = "Initial desired number of instances in the Auto Scaling Group."
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Maximum number of instances in the Auto Scaling Group."
  type        = number
  default     = 4
}

variable "cpu_target" {
  description = "Average CPU utilization target for target tracking, as a percentage."
  type        = number
  default     = 60
}

variable "instance_security_group_id" {
  description = "Security group ID attached to the application instances."
  type        = string
}

variable "load_balancer_target_group_arn" {
  description = "Target group ARN registered with the Auto Scaling Group."
  type        = string
}

variable "instance_profile_name" { type = string }
variable "aws_region" { type = string }
variable "application_repository_url" { type = string }
variable "application_commit_sha" { type = string }
variable "pull_deploy_timer_enabled" { type = bool }
variable "application_url" { type = string }
variable "database_endpoint" { type = string }
variable "database_name" { type = string }
variable "database_secret_arn" { type = string }
variable "app_key_secret_arn" { type = string }
variable "initial_admin_secret_arn" { type = string }
variable "initial_admin_name" { type = string }
variable "initial_admin_email" { type = string }
variable "efs_file_system_id" { type = string }
variable "efs_access_point_id" { type = string }

variable "auto_deploy_enabled" { type = bool }
