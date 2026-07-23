# Phase 3 — Cluster module

EKS control plane + IRSA foundation + Karpenter for node autoscaling.

**Inputs:** `name_prefix`, `vpc_id`, `subnet_ids` (private), `k8s_version`.
**Outputs:** `cluster_name`, `cluster_endpoint`, `oidc_provider_arn`,
`cluster_certificate_authority_data`.

Karpenter (NOT Cluster Autoscaler). Baseline managed node group stays tiny —
it only runs platform pods; the demo's worker pods land on Karpenter-provisioned
spot capacity. `oidc_provider_arn` is the most important output: platform and
app-resources modules need it to build IRSA roles.

## Implementation notes

- **Access:** `authentication_mode = "API"` (EKS access entries), not the
  aws-auth ConfigMap. The system node group gets its access entry from EKS
  automatically; Karpenter's node role does not (it isn't an EKS-managed
  node group), so it gets one explicit `aws_eks_access_entry` of type
  `EC2_LINUX` — that type implies the `system:bootstrappers`/`system:nodes`
  RBAC mapping. A `STANDARD` entry can't be used here: EKS rejects
  `system:`-prefixed group names on that type.
- **Karpenter IAM:** the controller policy is transcribed from AWS's official
  Karpenter getting-started CloudFormation template, split into the same five
  managed-policy groupings (node lifecycle, IAM integration, EKS integration,
  interruption, resource discovery). The sixth, ZonalShiftPolicy, is omitted —
  zonal autoshift isn't in scope for this single-region demo.
- **NodePool/EC2NodeClass** are applied via the `kubectl_manifest` resource
  (gavinbunney/kubectl provider), not `kubernetes_manifest` — the latter
  validates CRD schemas at plan time, which doesn't work when the CRDs are
  installed by the Karpenter Helm release in the same apply.
- **First apply caveat:** the kubernetes/helm/kubectl providers (configured in
  `environments/dev/main.tf`) authenticate against this cluster's endpoint,
  which doesn't exist yet on a from-scratch apply — and even once it exists,
  the control plane can be briefly overloaded while the system node group
  joins and the Karpenter chart deploys. Any resource that talks to the
  cluster can hit a connection error on the very first apply: the Karpenter
  `helm_release`, the NodePool/EC2NodeClass manifests, or ones further
  downstream like the `eda` namespace and the platform module's Helm releases
  (LB Controller, KEDA, Argo CD). Just re-run `terraform apply` — it's
  idempotent, so anything already created is left alone and only the failed
  resources retry once the cluster has settled.
- **k8s_version default (1.34):** check the current EKS standard-support
  version list before applying — this rolls over every few months and an
  outdated pin risks landing on extended support (6x control-plane cost).
