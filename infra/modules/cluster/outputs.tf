# Cluster module — outputs

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate."
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider — used by later modules to build IRSA roles."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "cluster_security_group_id" {
  description = "EKS-managed control-plane security group ID."
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}
