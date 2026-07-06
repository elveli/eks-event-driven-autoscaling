# Platform module — outputs

output "argocd_namespace" {
  description = "Namespace Argo CD runs in — the Application in gitops/apps targets a cluster, not this directly, but it's useful for kubectl/port-forward."
  value       = var.argocd_namespace
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN used by the AWS Load Balancer Controller."
  value       = aws_iam_role.lb_controller.arn
}

output "keda_role_arn" {
  description = "IRSA role ARN used by the KEDA operator. The ScaledObject's identityOwner: operator relies on this role being on the operator pod's ServiceAccount."
  value       = aws_iam_role.keda.arn
}
