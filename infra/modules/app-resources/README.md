# Phase 5 — App-resources module

Everything outside the cluster that the app talks to, plus the IRSA wiring.

**Inputs:** `name_prefix`, `oidc_provider_arn`.
**Outputs:** `jobs_queue_url`, `jobs_queue_arn`, `bucket_name`,
`worker_role_arn`, `ecr_web_url`, `ecr_worker_url`, `lambda_function_url`.

The `worker_role_arn` is what the worker's Kubernetes ServiceAccount annotates
for IRSA — that's how pods get SQS/S3 access with zero static credentials.
ECR repos must be immutable-tag + scan-on-push.
