# Phase 4 — Platform module

Cluster add-ons that make the demo work: ingress, event-driven scaling, GitOps.

**Inputs:** `cluster_name`, `oidc_provider_arn`, `vpc_id`.
**Outputs:** `argocd_namespace`, `lb_controller_role_arn`, `keda_role_arn`.

Three Helm releases, all version-pinned: AWS Load Balancer Controller, KEDA,
Argo CD. KEDA's operator gets an IRSA role allowing `sqs:GetQueueAttributes`
(+ CloudWatch read) so the SQS scaler can read queue depth.

## Implementation notes

- **LB Controller IAM policy** is vendored verbatim under `policies/` from
  `kubernetes-sigs/aws-load-balancer-controller`'s own
  `docs/install/iam_policy.json` — not hand-transcribed. It's long enough
  that a dropped statement would surface as a confusing ALB provisioning
  failure rather than an obvious error.
- **KEDA IRSA** uses the chart's own `podIdentity.aws.irsa.enabled` /
  `podIdentity.aws.irsa.roleArn` values (confirmed against the chart's
  `values.yaml` for the pinned version) rather than setting
  `serviceAccount.annotations` directly — the chart writes the
  `eks.amazonaws.com/role-arn` annotation onto the operator's ServiceAccount
  itself when these are set.
- **KEDA's SQS read policy is pre-scoped** to `<cluster_name>-*` even though
  the actual queue (Phase 5, `app-resources`) doesn't exist yet — IAM allows
  an ARN pattern to reference a resource that isn't created yet.
- **No Ingress for Argo CD itself** — CLAUDE.md scopes the ALB to the app
  (`gitops/manifests/ingress.yaml`), not the platform. Reach the Argo CD UI
  with `kubectl port-forward svc/argocd-server -n argocd 8080:443`; the
  initial admin password is in the `argocd-initial-admin-secret` Secret in
  the `argocd` namespace.
- **Chart versions were pulled from each project's live Helm repo index**
  (not memory) at the time this module was written: LB Controller 3.4.0,
  KEDA 2.20.1, Argo CD 10.1.2. Re-check these before applying if much time
  has passed — same caveat as the cluster module's `k8s_version`.
