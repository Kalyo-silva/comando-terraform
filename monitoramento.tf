resource "aws_cloudwatch_metric_alarm" "comando_http_5xx" {
  alarm_name        = "comando-http-5xx"
  alarm_description = "Comando retornou 5 ou mais erros HTTP 5xx em 5 minutos."

  namespace          = "AWS/ApplicationELB"
  metric_name        = "HTTPCode_Target_5XX_Count"
  statistic          = "Sum"
  period             = 300
  evaluation_periods = 1

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 5

  treat_missing_data = "notBreaching"

  dimensions = {
    LoadBalancer = replace(
      split(":", module.load_balancer.arn)[5],
      "loadbalancer/",
      ""
    )
    TargetGroup = split(":", module.load_balancer.target_group_arn)[5]
  }

  tags = {
    Name      = "comando-http-5xx"
    ManagedBy = "Terraform"
  }
}
resource "aws_cloudwatch_metric_alarm" "comando_alb_sem_target" {
  alarm_name        = "comando-alb-sem-target-saudavel"
  alarm_description = "omando com menos de 2 instancias saudaveis no ALB."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2

  comparison_operator = "LessThanThreshold"
  threshold           = 2
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = replace(
      split(":", module.load_balancer.arn)[5],
      "loadbalancer/",
      ""
    )
    TargetGroup = split(":", module.load_balancer.target_group_arn)[5]
  }

  tags = {
    Name      = "comando-alb-sem-target-saudavel"
    ManagedBy = "Terraform"
  }
}
