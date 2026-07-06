# App-resources module — outputs

output "jobs_queue_url" {
  description = "Jobs queue URL — the worker's QUEUE_URL env var and the KEDA ScaledObject's queueURL."
  value       = aws_sqs_queue.jobs.url
}

output "jobs_queue_arn" {
  description = "Jobs queue ARN."
  value       = aws_sqs_queue.jobs.arn
}

output "bucket_name" {
  description = "Payload/results bucket — the worker's and Lambda's BUCKET env var."
  value       = aws_s3_bucket.jobs.bucket
}

output "worker_role_arn" {
  description = "IRSA role the eda-worker ServiceAccount annotates with eks.amazonaws.com/role-arn."
  value       = aws_iam_role.worker.arn
}

output "ecr_web_url" {
  description = "ECR repository URL for the web (dashboard) image."
  value       = aws_ecr_repository.repos["eda-web"].repository_url
}

output "ecr_worker_url" {
  description = "ECR repository URL for the worker image."
  value       = aws_ecr_repository.repos["eda-worker"].repository_url
}

output "lambda_function_url" {
  description = "Front-door Lambda Function URL — what the dashboard's nginx /api/ proxy points at."
  value       = aws_lambda_function_url.front_door.function_url
}

output "gha_role_arn" {
  description = "GitHub Actions CI role ARN — set this as the AWS_ROLE_ARN repository variable; the workflows reference it instead of a hardcoded ARN."
  value       = aws_iam_role.gha.arn
}
