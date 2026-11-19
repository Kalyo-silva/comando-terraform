module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

module "load_balancer" {
  source = "./modules/load_balancer"

  project_name      = var.project_name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
}

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "Allow application traffic from the ALB and optional restricted SSH."
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "HTTP from the Application Load Balancer."
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [module.load_balancer.security_group_id]
  }

  dynamic "ingress" {
    for_each = var.ssh_allowed_cidrs
    content {
      description = "SSH from an explicitly allowed CIDR."
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "Allow outbound connections."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "${var.project_name}-ec2-sg"
    ManagedBy = "Terraform"
  }
}

module "shared_storage" {
  source = "./modules/shared_storage"

  project_name                  = var.project_name
  vpc_id                        = module.vpc.vpc_id
  private_subnet_ids            = module.vpc.private_subnet_ids
  application_security_group_id = aws_security_group.ec2.id
}

resource "random_id" "app_key" {
  byte_length = 32
}

resource "aws_secretsmanager_secret" "app_key" {
  name        = "${var.project_name}/comando/app-key"
  description = "Shared Laravel APP_KEY for all Comando EC2 instances."
}

resource "aws_secretsmanager_secret_version" "app_key" {
  secret_id     = aws_secretsmanager_secret.app_key.id
  secret_string = "base64:${random_id.app_key.b64_std}"
}

resource "random_password" "initial_admin" {
  length      = 24
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

resource "aws_secretsmanager_secret" "initial_admin" {
  name        = "${var.project_name}/comando/initial-admin"
  description = "Generated initial Comando administrator password."
}

resource "aws_secretsmanager_secret_version" "initial_admin" {
  secret_id = aws_secretsmanager_secret.initial_admin.id
  secret_string = jsonencode({
    password = random_password.initial_admin.result
    name     = var.initial_admin_name
    email    = var.initial_admin_email
  })
}

module "autoscaling" {
  source = "./modules/autoscaling"

  project_name                   = var.project_name
  public_subnet_ids              = module.vpc.public_subnet_ids
  instance_type                  = var.ec2_instance_type
  min_size                       = var.asg_min_size
  desired_capacity               = var.asg_desired_capacity
  max_size                       = var.asg_max_size
  cpu_target                     = var.asg_cpu_target
  instance_security_group_id     = aws_security_group.ec2.id
  load_balancer_target_group_arn = module.load_balancer.target_group_arn
  instance_profile_name          = var.ec2_instance_profile_name
  aws_region                     = var.aws_region
  application_repository_url     = var.application_repository_url
  application_commit_sha         = var.application_commit_sha
  pull_deploy_timer_enabled      = var.pull_deploy_timer_enabled
  application_url                = "http://${module.load_balancer.dns_name}"
  database_endpoint              = module.rds.endpoint
  database_name                  = module.rds.database_name
  database_secret_arn            = module.rds.master_user_secret_arn
  app_key_secret_arn             = aws_secretsmanager_secret.app_key.arn
  initial_admin_secret_arn       = aws_secretsmanager_secret.initial_admin.arn
  initial_admin_name             = var.initial_admin_name
  initial_admin_email            = var.initial_admin_email
  efs_file_system_id             = module.shared_storage.file_system_id
  efs_access_point_id            = module.shared_storage.access_point_id

  depends_on = [module.shared_storage]
}

module "rds" {
  source = "./modules/rds"

  project_name                  = var.project_name
  vpc_id                        = module.vpc.vpc_id
  private_subnet_ids            = module.vpc.private_subnet_ids
  application_security_group_id = aws_security_group.ec2.id
  instance_class                = var.db_instance_class
  allocated_storage             = var.db_allocated_storage
  database_name                 = var.db_name
  master_username               = var.db_master_username
}
