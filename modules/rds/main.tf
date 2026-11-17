data "aws_rds_engine_version" "postgres" {
  engine  = "postgres"
  version = "17"
  latest  = true
}

resource "aws_db_subnet_group" "this" {
  name        = "${var.project_name}-postgres-subnets"
  description = "Private subnets for the PostgreSQL database."
  subnet_ids  = var.private_subnet_ids

  tags = {
    Name      = "${var.project_name}-postgres-subnets"
    ManagedBy = "Terraform"
  }
}

resource "aws_security_group" "database" {
  name        = "${var.project_name}-postgres-sg"
  description = "Allow PostgreSQL connections from the EC2 Auto Scaling Group only."
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from the EC2 Auto Scaling Group."
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.application_security_group_id]
  }

  egress {
    description = "Allow outbound connections."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "${var.project_name}-postgres-sg"
    ManagedBy = "Terraform"
  }
}

resource "aws_db_instance" "this" {
  identifier                  = "${var.project_name}-postgres"
  engine                      = "postgres"
  engine_version              = data.aws_rds_engine_version.postgres.version
  instance_class              = var.instance_class
  allocated_storage           = var.allocated_storage
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = var.database_name
  username                    = var.master_username
  manage_master_user_password = true
  port                        = 5432
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.database.id]
  publicly_accessible         = false
  multi_az                    = false
  backup_retention_period     = 1
  auto_minor_version_upgrade  = true
  deletion_protection         = false
  skip_final_snapshot         = true
  apply_immediately           = false

  tags = {
    Name      = "${var.project_name}-postgres"
    ManagedBy = "Terraform"
  }
}
