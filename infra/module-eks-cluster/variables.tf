variable "cluster_name" {
  description = "EKS cluster name. Becomes part of the nodegroup and IAM role names."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version. Defaults to the latest stable version we've validated for articles."
  type        = string
  # Must stay on STANDARD_SUPPORT: extended support costs $0.60/hr vs $0.10/hr.
  default = "1.36"
}

variable "vpc_id" {
  description = "VPC ID where the cluster will live. Typically a dependency output from the vpc stack."
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for cluster control plane and nodes. Private subnets recommended; public is fine for testing."
  type        = list(string)
}

variable "cluster_endpoint_public_access" {
  description = "Allow kubectl from anywhere. True is convenient for article testing, false for production."
  type        = bool
  default     = true
}

# Nodegroup sizing
variable "node_instance_types" {
  description = "EC2 instance types for the nodegroup. t3.medium is the cheap default that handles most article workloads."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. Spot is cheaper but can disappear mid-test."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_min_size" {
  description = "Minimum nodes in the nodegroup."
  type        = number
  default     = 2
}

variable "node_desired_size" {
  description = "Desired nodes in the nodegroup."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum nodes in the nodegroup."
  type        = number
  default     = 4
}

variable "node_disk_size" {
  description = "Root EBS volume size in GB for each worker node."
  type        = number
  default     = 30
}

variable "extra_access_entries" {
  description = "Additional EKS access entries beyond the cluster creator. Use this to grant kubectl access to teammates."
  type        = any
  default     = {}
}

variable "common_tags" {
  description = "Tags applied to every EKS-related resource."
  type        = map(string)
  default     = {}
}
