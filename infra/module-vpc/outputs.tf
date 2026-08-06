output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID of the created VPC."
}

output "vpc_arn" {
  value = module.vpc.vpc_arn
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  value       = module.vpc.public_subnets
  description = "IDs of the public subnets (IGW-routed)."
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnets
  description = "IDs of the private subnets (NAT Gateway-routed if enable_nat_gateway=true)."
}

output "public_subnet_cidrs" {
  value = module.vpc.public_subnets_cidr_blocks
}

output "private_subnet_cidrs" {
  value = module.vpc.private_subnets_cidr_blocks
}

output "nat_gateway_ids" {
  value = module.vpc.natgw_ids
}

output "nat_public_ips" {
  value = module.vpc.nat_public_ips
}

output "internet_gateway_id" {
  value = module.vpc.igw_id
}

output "default_security_group_id" {
  value = module.vpc.default_security_group_id
}

output "azs" {
  value = module.vpc.azs
}
