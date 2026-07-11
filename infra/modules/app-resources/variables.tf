# App-resources module — inputs

variable "name_prefix" {
  type        = string
  description = "Short resource prefix, e.g. eda-dev. Must match the KEDA operator's pre-scoped SQS-read policy (<cluster_name>-*) from the platform module."
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the cluster's IAM OIDC provider (from the cluster module) — used to build the worker's IRSA trust policy."
}

variable "github_repo" {
  type        = string
  description = "GitHub org/repo allowed to assume the CI role via OIDC federation."
  default     = "elveli/eks-event-driven-autoscaling"
}

variable "create_github_oidc_provider" {
  type        = bool
  description = "Whether to create the account-wide GitHub Actions OIDC provider (issuer token.actions.githubusercontent.com). AWS allows only one per account; if another project sharing this AWS account already created it, set this to false here so this module reuses it (check with: aws iam list-open-id-connect-providers). Whichever project creates it \"owns\" it for destroy purposes."
  default     = true
}

variable "state_bucket_basename" {
  type        = string
  description = "Terraform state bucket name minus the account-id suffix (the full name is <basename>-<account_id>, as created by infra/bootstrap). The CI role gets read access to it for terraform plan."
  default     = "eks-event-driven-autoscaling-tfstate"
}

variable "lock_table_name" {
  type        = string
  description = "DynamoDB lock table name (as created by infra/bootstrap). The CI role needs lock access for terraform plan."
  default     = "eda-tf-locks"
}

variable "job_visibility_timeout" {
  type        = number
  description = "Jobs-queue visibility timeout in seconds. Must exceed the worker's per-job processing time or in-flight jobs get redelivered mid-work. Tune in Phase 6."
  default     = 120
}
