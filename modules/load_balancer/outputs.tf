output "dns_name" {
  description = "DNS name of the public Application Load Balancer."
  value       = aws_lb.this.dns_name
}

output "arn" {
  description = "ARN of the Application Load Balancer."
  value       = aws_lb.this.arn
}

output "target_group_arn" {
  description = "ARN of the HTTP target group registered with the Auto Scaling Group."
  value       = aws_lb_target_group.http.arn
}

output "security_group_id" {
  description = "ID of the ALB security group."
  value       = aws_security_group.alb.id
}

output "web_acl_arn" {
  description = "ARN of the regional AWS WAF Web ACL associated with the ALB."
  value       = aws_wafv2_web_acl.this.arn
}
