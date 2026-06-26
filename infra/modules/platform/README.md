# Phase 4 — Platform module

Cluster add-ons that make the demo work: ingress, event-driven scaling, GitOps.

**Inputs:** `cluster_name`, `oidc_provider_arn`, cluster endpoint/CA for the
helm + kubernetes providers.
**Outputs:** `argocd_namespace`, `lb_controller_role_arn`, `keda_role_arn`.

Three Helm releases, all version-pinned: AWS Load Balancer Controller, KEDA,
Argo CD. KEDA's operator gets an IRSA role allowing `sqs:GetQueueAttributes`
(+ CloudWatch read) so the SQS scaler can read queue depth.
