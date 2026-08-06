include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${dirname(find_in_parent_folders())}/../module-eks-cluster"
}

dependency "vpc" {
  config_path = "../vpc"
}

inputs = {
  cluster_name = "cfg-lab-eks"
  vpc_id       = dependency.vpc.outputs.vpc_id
  subnet_ids   = dependency.vpc.outputs.private_subnet_ids

  # 1.36 is on STANDARD_SUPPORT. An extended-support version bills the control
  # plane at $0.60/hr instead of $0.10/hr for the same cluster.
  cluster_version = "1.36"

  # Argo CD + Rollouts + kube-prometheus-stack + the app + an in-cluster k6 job
  # do not fit on 2x t3.medium without evictions.
  node_instance_types = ["t3.large"]
  node_min_size       = 3
  node_desired_size   = 3
  node_max_size       = 4
}
