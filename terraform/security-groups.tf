# Security group for secondary ENIs on bare-metal nodes (tenant traffic).
# OCP IPI creates its own security groups for the primary ENIs; this SG
# is only for the secondary ENIs carrying VLAN bridge traffic.

resource "aws_security_group" "tenant_network" {
  name_prefix = "${var.cluster_name_prefix}-tenant-"
  description = "Tenant VLAN bridge traffic on secondary ENIs"
  vpc_id      = aws_vpc.main.id

  # Allow all traffic within the tenant subnets (bridge, VLAN, overlay)
  ingress {
    description = "All traffic within tenant subnets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = var.tenant_subnet_cidrs
  }

  # Allow all traffic from the private subnets (node-to-node)
  ingress {
    description = "Traffic from cluster nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = var.private_subnet_cidrs
  }

  # Allow all outbound (for NAT gateway / Konnectivity)
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name_prefix}-tenant-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Security group rule to allow cross-cluster API access.
# Added to the VPC default SG so both clusters can communicate.
resource "aws_security_group" "cross_cluster" {
  name_prefix = "${var.cluster_name_prefix}-cross-cluster-"
  description = "Cross-cluster API and Konnectivity access"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "OpenShift API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "HTTPS (Konnectivity Routes, ingress)"
    from_port   = 443
    to_port     = 443
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
    Name = "${var.cluster_name_prefix}-cross-cluster-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}
