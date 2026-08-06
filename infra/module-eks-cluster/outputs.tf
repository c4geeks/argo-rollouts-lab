output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_arn" {
  value = module.eks.cluster_arn
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Base64-encoded CA cert for the cluster. Needed by the kubernetes/helm providers."
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}

output "oidc_provider_arn" {
  value       = module.eks.oidc_provider_arn
  description = "ARN of the IAM OIDC provider for IRSA trust policies."
}

output "oidc_provider_url" {
  value       = module.eks.cluster_oidc_issuer_url
  description = "OIDC issuer URL (with https:// prefix)."
}

output "nodegroup_iam_role_arn" {
  value = values(module.eks.eks_managed_node_groups)[0].iam_role_arn
}

output "kubeconfig_command" {
  description = "One-liner to populate kubectl context for this cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${data.aws_region.current.region}"
}
