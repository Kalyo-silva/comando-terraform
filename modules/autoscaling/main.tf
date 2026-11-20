data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  user_data = base64gzip(replace(templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region                 = var.aws_region
    application_repository_url = var.application_repository_url
    application_commit_sha     = var.application_commit_sha
    application_url            = var.application_url
    database_endpoint          = var.database_endpoint
    database_name              = var.database_name
    database_secret_arn        = var.database_secret_arn
    app_key_secret_arn         = var.app_key_secret_arn
    initial_admin_secret_arn   = var.initial_admin_secret_arn
    initial_admin_name         = var.initial_admin_name
    initial_admin_email        = var.initial_admin_email
    efs_file_system_id         = var.efs_file_system_id
    efs_access_point_id        = var.efs_access_point_id
    pull_deploy_timer_enabled  = var.pull_deploy_timer_enabled
    auto_deploy_enabled        = var.auto_deploy_enabled
    pull_deploy_scripts = {
      for name in ["pull-deploy.sh", "check-deploy-ci.sh", "check-schema.php", "deploy-lock.php", "auto-pull.sh"] :
      name => file("${path.root}/scripts/${name}")
    }
  }), "\r\n", "\n"))
}

resource "aws_launch_template" "instances" {
  name_prefix   = "${var.project_name}-ec2-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  user_data     = local.user_data

  lifecycle {
    precondition {
      condition     = !var.auto_deploy_enabled || (var.min_size == 1 && var.max_size == 1 && var.desired_capacity == 1)
      error_message = "Auto deploy currently supports a single EC2 only: min_size, max_size and desired_capacity must all be 1."
    }
    precondition {
      condition     = !var.auto_deploy_enabled || var.pull_deploy_timer_enabled
      error_message = "Automatic deployment requires the periodic CI poll timer enabled."
    }
    precondition {
      condition     = length(local.user_data) * 3 / 4 - length(regex("=*$", local.user_data)) <= 16384
      error_message = "Compressed EC2 user data must fit within 16 KiB."
    }
    precondition {
      condition     = !(var.pull_deploy_timer_enabled || var.auto_deploy_enabled) || can(regex("^https://github\\.com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$", var.application_repository_url))
      error_message = "The pull deploy timer requires an HTTPS GitHub repository URL without embedded credentials."
    }
  }

  vpc_security_group_ids = [var.instance_security_group_id]

  iam_instance_profile {
    name = var.instance_profile_name
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name      = "${var.project_name}-ec2"
      ManagedBy = "Terraform"
    }
  }
}

resource "aws_autoscaling_group" "instances" {
  name                      = "${var.project_name}-ec2-asg"
  min_size                  = var.min_size
  desired_capacity          = var.desired_capacity
  max_size                  = var.max_size
  vpc_zone_identifier       = var.public_subnet_ids
  target_group_arns         = [var.load_balancer_target_group_arn]
  health_check_type         = "ELB"
  health_check_grace_period = 1800
  default_instance_warmup   = 300

  launch_template {
    id      = aws_launch_template.instances.id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = {
      Name      = "${var.project_name}-ec2"
      ManagedBy = "Terraform"
    }

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                      = "${var.project_name}-cpu-target-tracking"
  policy_type               = "TargetTrackingScaling"
  autoscaling_group_name    = aws_autoscaling_group.instances.name
  estimated_instance_warmup = 300

  target_tracking_configuration {
    target_value = var.cpu_target

    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
  }
}
