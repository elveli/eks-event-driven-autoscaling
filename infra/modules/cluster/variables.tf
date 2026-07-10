# Cluster module — inputs

variable "name_prefix" {
  type        = string
  description = "Short resource prefix, e.g. eda-dev. Used as the EKS cluster name."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs from the network module. Hosts the control plane ENIs, the system node group, and Karpenter-launched nodes."
}

variable "k8s_version" {
  type        = string
  description = "EKS Kubernetes version. Keep on a CURRENT (standard support) version — extended support bills 6x on the control plane."
  default     = "1.34"
}

variable "system_node_instance_type" {
  type        = string
  description = "Instance type for the small managed node group that hosts system pods (Karpenter, KEDA, Argo CD, LB Controller)."
  default     = "t3.medium"
}

variable "system_node_count" {
  type        = number
  description = "Fixed size of the system managed node group. Kept small and constant — real workers run on Karpenter capacity."
  default     = 2
}

variable "karpenter_version" {
  type        = string
  description = "Karpenter Helm chart version (pinned)."
  default     = "1.13.0"
}

variable "karpenter_namespace" {
  type        = string
  description = "Namespace Karpenter is installed into."
  default     = "karpenter"
}
