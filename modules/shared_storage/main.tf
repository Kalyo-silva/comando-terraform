resource "aws_security_group" "efs" {
  name        = "${var.project_name}-efs-sg"
  description = "Allow NFS from the EC2 Auto Scaling Group only."
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from the application EC2 instances."
    from_port       = 2049
    to_port         = 2049
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
    Name      = "${var.project_name}-efs-sg"
    ManagedBy = "Terraform"
  }
}

resource "aws_efs_file_system" "this" {
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = {
    Name      = "${var.project_name}-attachments"
    ManagedBy = "Terraform"
  }
}

resource "aws_efs_mount_target" "private" {
  count           = length(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "attachments" {
  file_system_id = aws_efs_file_system.this.id

  posix_user {
    uid = 82
    gid = 82
  }

  root_directory {
    path = "/comando/anexos"

    creation_info {
      owner_uid   = 82
      owner_gid   = 82
      permissions = "0770"
    }
  }

  tags = {
    Name      = "${var.project_name}-attachments"
    ManagedBy = "Terraform"
  }
}
