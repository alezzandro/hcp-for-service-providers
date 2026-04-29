# EFS filesystem for KubeVirt RWX storage (live migration).
# All resources are conditional on var.enable_efs.

resource "aws_efs_file_system" "kubevirt" {
  count = var.enable_efs ? 1 : 0

  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = {
    Name = "${var.cluster_name_prefix}-kubevirt-efs"
  }
}

resource "aws_security_group" "efs" {
  count = var.enable_efs ? 1 : 0

  name_prefix = "${var.cluster_name_prefix}-efs-"
  description = "NFS access to EFS from VPC nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "NFS from VPC"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name_prefix}-efs-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_efs_mount_target" "private" {
  count = var.enable_efs ? length(var.availability_zones) : 0

  file_system_id  = aws_efs_file_system.kubevirt[0].id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs[0].id]
}

# --- Outputs (empty string when EFS is disabled) ---

output "efs_filesystem_id" {
  description = "EFS filesystem ID for KubeVirt RWX storage (empty when disabled)"
  value       = var.enable_efs ? aws_efs_file_system.kubevirt[0].id : ""
}

output "efs_security_group_id" {
  description = "Security group ID for EFS NFS access (empty when disabled)"
  value       = var.enable_efs ? aws_security_group.efs[0].id : ""
}
