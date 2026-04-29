resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name_prefix}-vpc"
  }
}

# --- Internet Gateway ---

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name_prefix}-igw"
  }
}

# --- Public Subnets ---

resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                               = "${var.cluster_name_prefix}-public-${var.availability_zones[count.index]}"
    "kubernetes.io/role/elb"                            = "1"
    "kubernetes.io/cluster/${local.hub_infra_id}"       = "shared"
    "kubernetes.io/cluster/${local.virt_infra_id}"      = "shared"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- NAT Gateway (single, in first AZ) ---

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.cluster_name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# --- Private Subnets ---

resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                                               = "${var.cluster_name_prefix}-private-${var.availability_zones[count.index]}"
    "kubernetes.io/role/internal-elb"                   = "1"
    "kubernetes.io/cluster/${local.hub_infra_id}"       = "shared"
    "kubernetes.io/cluster/${local.virt_infra_id}"      = "shared"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Tenant Subnets (secondary ENI for bare-metal nodes) ---

resource "aws_subnet" "tenant" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.tenant_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                              = "${var.cluster_name_prefix}-tenant-${var.availability_zones[count.index]}"
    "kubernetes.io/cluster/unmanaged" = "true"
  }
}

resource "aws_route_table" "tenant" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name_prefix}-tenant-rt"
  }
}

resource "aws_route_table_association" "tenant" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.tenant[count.index].id
  route_table_id = aws_route_table.tenant.id
}
