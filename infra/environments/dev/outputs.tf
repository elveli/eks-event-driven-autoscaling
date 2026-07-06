# TODO: surface alb_dns_name, queue_url, etc. as you build later phases.

output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "argocd_namespace" {
  value = module.platform.argocd_namespace
}

output "lb_controller_role_arn" {
  value = module.platform.lb_controller_role_arn
}

output "keda_role_arn" {
  value = module.platform.keda_role_arn
}
