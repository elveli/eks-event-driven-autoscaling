# Platform module — inputs

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (from the cluster module). Names IAM roles and is passed to the LB Controller chart."
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the cluster's IAM OIDC provider (from the cluster module) — used to build IRSA trust policies."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID (from the network module). Passed to the LB Controller chart so it doesn't have to discover it via IMDS."
}

variable "lb_controller_version" {
  type        = string
  description = "AWS Load Balancer Controller Helm chart version (pinned)."
  default     = "3.4.0"
}

variable "lb_controller_namespace" {
  type        = string
  description = "Namespace the LB Controller is installed into. kube-system is AWS's documented convention."
  default     = "kube-system"
}

variable "keda_version" {
  type        = string
  description = "KEDA Helm chart version (pinned)."
  default     = "2.20.1"
}

variable "keda_namespace" {
  type        = string
  description = "Namespace KEDA is installed into."
  default     = "keda"
}

variable "argocd_version" {
  type        = string
  description = "Argo CD Helm chart version (pinned)."
  default     = "10.1.2"
}

variable "argocd_namespace" {
  type        = string
  description = "Namespace Argo CD is installed into."
  default     = "argocd"
}

variable "metrics_server_version" {
  type        = string
  description = "metrics-server Helm chart version (pinned)."
  default     = "3.13.1"
}

variable "metrics_server_namespace" {
  type        = string
  description = "Namespace metrics-server is installed into. kube-system matches AWS's documented EKS convention."
  default     = "kube-system"
}
