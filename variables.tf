variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
}

variable "project_name" {
  description = "Prefix used to name project resources."
  type        = string
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the VPC."
  type        = string
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, ordered by availability zone."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private database subnets, ordered by availability zone."
  type        = list(string)
}

variable "availability_zones" {
  description = "Availability zones used by the public and private subnets."
  type        = list(string)
}

variable "ec2_instance_type" {
  description = "EC2 instance type used by the Auto Scaling Group."
  type        = string
  default     = "t2.medium"
}

variable "asg_min_size" {
  description = "Minimum number of instances in the Auto Scaling Group."
  type        = number
  default     = 1
}

variable "asg_desired_capacity" {
  description = "Initial desired number of instances in the Auto Scaling Group."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of instances in the Auto Scaling Group."
  type        = number
  default     = 4
}

variable "asg_cpu_target" {
  description = "Average CPU utilization target used by target tracking scaling."
  type        = number
  default     = 60
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 CIDR blocks allowed to connect to the instances over SSH. Empty disables inbound SSH."
  type        = list(string)
  default     = []
}

variable "ec2_instance_profile_name" {
  description = "Existing EC2 instance profile supplied by the AWS Academy lab."
  type        = string
}

variable "db_instance_class" {
  description = "RDS PostgreSQL instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage allocation in GiB."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Name of the initial PostgreSQL database."
  type        = string
  default     = "comando"
}

variable "db_master_username" {
  description = "Master username for the PostgreSQL database."
  type        = string
  default     = "comando"
}

variable "application_repository_url" {
  description = "Git URL used by EC2 instances to fetch the application source."
  type        = string
  default     = "https://github.com/CarlosEduardo-N-O/comando.git"
}

variable "application_commit_sha" {
  description = "Immutable application commit deployed by the EC2 instances."
  type        = string
  default     = "0f9e06f9ae3456c3905fbc96d7857ca7d0e3c5f8"
}

variable "pull_deploy_timer_enabled" {
  description = "Enable periodic pull deploy dry-runs on newly launched EC2 instances."
  type        = bool
  default     = false
}

variable "initial_admin_name" {
  description = "Display name of the first Comando administrator."
  type        = string
  default     = "Administrador"
}

variable "initial_admin_email" {
  description = "Login email for the first Comando administrator. Change before deployment if needed."
  type        = string
  default     = "admin@comando.local"
}
