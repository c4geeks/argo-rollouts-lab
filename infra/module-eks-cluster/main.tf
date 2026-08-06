# ------------------------------------------------------------------------------
# EKS Cluster module — thin wrapper around terraform-aws-modules/eks/aws
# ------------------------------------------------------------------------------
# Opinionated for article testing:
#   - Managed nodegroup with t3.medium nodes (cheap and adequate for most demos)
#   - OIDC provider enabled (needed for IRSA and Pod Identity associations)
#   - EKS Pod Identity Agent addon installed by default
#   - Access entries pre-wired for the caller (so kubectl works out of the box)
#   - Public endpoint accessible (convenient for article testing, NOT production)
#
# Inputs come from the caller's VPC stack (dependency in Terragrunt).
# ------------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  # Pull the first three private subnets for cluster placement, first two for the nodegroup.
  cluster_subnet_ids   = var.subnet_ids
  nodegroup_subnet_ids = slice(var.subnet_ids, 0, min(length(var.subnet_ids), 2))
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.17"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  endpoint_public_access  = var.cluster_endpoint_public_access
  endpoint_private_access = true

  # Required for IRSA. Pod Identity does NOT require this, but having it
  # enabled costs nothing extra and lets articles demo both mechanisms.
  enable_irsa = true

  vpc_id     = var.vpc_id
  subnet_ids = local.cluster_subnet_ids

  # ----------------------------------------------------------------------------
  # Cluster addons (the ones every EKS cluster needs to function)
  # ----------------------------------------------------------------------------
  addons = {
    # vpc-cni MUST install before the nodegroup forms, otherwise nodes can't
    # bring up CNI and stay NotReady forever (chicken-and-egg).
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  # ----------------------------------------------------------------------------
  # Managed nodegroup (one, small, cheap)
  # ----------------------------------------------------------------------------
  eks_managed_node_groups = {
    workers = {
      name = "${var.cluster_name}-workers"

      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      subnet_ids = local.nodegroup_subnet_ids

      disk_size = var.node_disk_size
      disk_type = "gp3"

      labels = {
        managed-by = "terragrunt"
        role       = "general"
      }

      tags = var.common_tags
    }
  }

  # ----------------------------------------------------------------------------
  # Access entries: give the caller (the IAM identity running terragrunt apply)
  # cluster-admin access automatically. Otherwise kubectl won't work without an
  # extra aws-auth configmap dance.
  # ----------------------------------------------------------------------------
  enable_cluster_creator_admin_permissions = true

  access_entries = var.extra_access_entries

  tags = var.common_tags
}
