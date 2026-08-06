variable "name" {
  description = "Name for the VPC. Applied as the Name tag and as a prefix for child resources."
  type        = string
}

variable "cidr" {
  description = "VPC IPv4 CIDR block. A /16 gives plenty of headroom for article testing."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across. Three is the safe default for EKS and RDS multi-AZ."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3 (EKS and RDS need at least 2 AZs)."
  }
}

variable "enable_nat_gateway" {
  description = "Whether to create a NAT Gateway. Set to false for articles that only need public subnets (EC2, RDS with public access, etc)."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Share one NAT Gateway across all AZs instead of one per AZ. True saves ~$64/mo in a 3-AZ setup and is fine for testing."
  type        = bool
  default     = true
}

variable "enable_flow_log" {
  description = "Enable VPC flow logs to CloudWatch. Off by default because CloudWatch Logs ingestion costs add up fast."
  type        = bool
  default     = false
}

variable "eks_cluster_name" {
  description = "If set, subnet tags for EKS and Karpenter are added automatically. Leave null for non-EKS VPCs."
  type        = string
  default     = null
}

variable "public_subnet_tags" {
  description = "Extra tags applied to public subnets."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Extra tags applied to private subnets."
  type        = map(string)
  default     = {}
}

variable "common_tags" {
  description = "Tags applied to every resource in the VPC module. Comes from the root Terragrunt config by default."
  type        = map(string)
  default     = {}
}
