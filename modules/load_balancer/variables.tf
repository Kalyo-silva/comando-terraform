variable "project_name" {
  description = "Prefix used to name load balancer and WAF resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the ALB security group and target group are created."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the internet-facing ALB."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "The Application Load Balancer must span at least two public subnets."
  }
}
