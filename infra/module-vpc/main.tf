# ------------------------------------------------------------------------------
# VPC module — thin wrapper around terraform-aws-modules/vpc/aws
# ------------------------------------------------------------------------------
# Opinionated for article testing:
#   - Single NAT Gateway by default (~$32/mo vs ~$96/mo for per-AZ)
#   - 3 AZs with /20 public + /20 private subnets
#   - EKS-friendly subnet tags applied when `eks_cluster_name` is set
#   - Flow logs DISABLED (they cost money; enable if the article needs them)
#   - VPC endpoints DISABLED (they cost money; enable if the article needs them)
#
# If you need a production-grade VPC, use the tiko-platform-terraform base module
# instead. This one is built for throwaway article testing.
# ------------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # EKS-specific subnet tags get added only when this VPC is intended for an EKS cluster.
  eks_public_tags = var.eks_cluster_name == null ? {} : {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    "kubernetes.io/role/elb"                        = "1"
  }

  eks_private_tags = var.eks_cluster_name == null ? {} : {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"               = "1"
    "karpenter.sh/discovery"                        = var.eks_cluster_name
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.name
  cidr = var.cidr

  azs             = local.azs
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.cidr, 4, i)]
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.cidr, 4, i + var.az_count)]

  # Cost-conscious NAT: one gateway shared across all AZs unless caller opts out.
  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway && var.enable_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Flow logs off by default. Article testing doesn't need them and they cost money.
  enable_flow_log = var.enable_flow_log

  public_subnet_tags  = merge(var.public_subnet_tags, local.eks_public_tags)
  private_subnet_tags = merge(var.private_subnet_tags, local.eks_private_tags)

  tags = merge(
    var.common_tags,
    {
      Name = var.name
    }
  )
}
