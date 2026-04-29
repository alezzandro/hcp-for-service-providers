terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        "demo"       = "hcp-network-isolation"
        "managed-by" = "terraform"
      },
      var.tags
    )
  }
}

locals {
  hub_infra_id  = "${var.cluster_name_prefix}-${var.hub_cluster_name}"
  virt_infra_id = "${var.cluster_name_prefix}-${var.virt_cluster_name}"
}
