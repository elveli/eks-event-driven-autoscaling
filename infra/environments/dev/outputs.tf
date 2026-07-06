# TODO: surface alb_dns_name once the app Ingress exists (phase 6).

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

output "jobs_queue_url" {
  value = module.app_resources.jobs_queue_url
}

output "bucket_name" {
  value = module.app_resources.bucket_name
}

output "worker_role_arn" {
  value = module.app_resources.worker_role_arn
}

output "ecr_web_url" {
  value = module.app_resources.ecr_web_url
}

output "ecr_worker_url" {
  value = module.app_resources.ecr_worker_url
}

output "lambda_function_url" {
  value = module.app_resources.lambda_function_url
}

output "gha_role_arn" {
  value = module.app_resources.gha_role_arn
}
