# Phase 3 — Cluster module

EKS control plane + IRSA foundation + Karpenter for node autoscaling.

**Inputs:** `name_prefix`, `vpc_id`, `subnet_ids` (private), `k8s_version`.
**Outputs:** `cluster_name`, `cluster_endpoint`, `oidc_provider_arn`,
`cluster_certificate_authority_data`.

Karpenter (NOT Cluster Autoscaler). Baseline managed node group stays tiny —
it only runs platform pods; the demo's worker pods land on Karpenter-provisioned
spot capacity. `oidc_provider_arn` is the most important output: platform and
app-resources modules need it to build IRSA roles.
