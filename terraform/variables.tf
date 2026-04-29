variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-2"
}

variable "cluster_name_prefix" {
  description = "Prefix for naming all resources (VPC, subnets, tags)"
  type        = string
  default     = "hcp-demo"
}

variable "base_domain" {
  description = "Route53 base domain (must already exist as a public hosted zone)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the shared VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to use (must be in the selected region)"
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b", "us-east-2c"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "tenant_subnet_cidrs" {
  description = "CIDR blocks for tenant subnets / secondary ENI (one per AZ)"
  type        = list(string)
  default     = ["10.0.100.0/24", "10.0.101.0/24", "10.0.102.0/24"]
}

variable "hub_cluster_name" {
  description = "Name for the hub OCP cluster (used in DNS, tags)"
  type        = string
  default     = "hub"
}

variable "virt_cluster_name" {
  description = "Name for the OCP Virt infrastructure cluster"
  type        = string
  default     = "virt"
}

variable "enable_efs" {
  description = "Create an EFS filesystem for KubeVirt RWX live migration"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied to all resources"
  type        = map(string)
  default     = {}
}
