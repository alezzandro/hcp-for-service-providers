output "vpc_id" {
  description = "VPC ID for the shared VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (for load balancers)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (for cluster nodes)"
  value       = aws_subnet.private[*].id
}

output "tenant_subnet_ids" {
  description = "Tenant subnet IDs (for secondary ENIs)"
  value       = aws_subnet.tenant[*].id
}

output "tenant_security_group_id" {
  description = "Security group ID for tenant network secondary ENIs"
  value       = aws_security_group.tenant_network.id
}

output "cross_cluster_security_group_id" {
  description = "Security group ID for cross-cluster API access"
  value       = aws_security_group.cross_cluster.id
}

output "route53_zone_id" {
  description = "Route53 hosted zone ID for the base domain"
  value       = data.aws_route53_zone.base.zone_id
}

output "base_domain" {
  description = "Base domain for DNS records"
  value       = var.base_domain
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "availability_zones" {
  description = "Availability zones in use"
  value       = var.availability_zones
}

# Mapping of AZ to tenant subnet ID for the secondary ENI attachment script
output "az_tenant_subnet_map" {
  description = "Map of AZ name to tenant subnet ID"
  value       = zipmap(var.availability_zones, aws_subnet.tenant[*].id)
}
