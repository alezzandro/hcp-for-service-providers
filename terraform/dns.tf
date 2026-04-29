# Look up the existing public hosted zone for the base domain.
# The zone must already exist in Route53 before running Terraform.
data "aws_route53_zone" "base" {
  name         = var.base_domain
  private_zone = false
}
