include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${dirname(find_in_parent_folders())}/../module-vpc"
}

inputs = {
  name = "cfg-lab-vpc"
  cidr = "10.42.0.0/16"

  # Tags the subnets so the AWS Load Balancer Controller can discover them.
  # Without these the ALB never gets created and the Ingress sits pending.
  eks_cluster_name = "cfg-lab-eks"

  az_count           = 3
  enable_nat_gateway = true
  single_nat_gateway = true
}
