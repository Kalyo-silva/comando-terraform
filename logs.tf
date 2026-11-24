resource "aws_cloudwatch_log_group" "comando_deploy" {
  name              = "/comando/deploy"
  retention_in_days = 7

  tags = {
    Name      = "comando-deploy"
    ManagedBy = "Terraform"
  }
}
