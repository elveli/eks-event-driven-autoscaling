# CLAUDE.md — EKS Event-Driven Autoscaling

Project context for Claude Code. Read this fully at the start of every session.
This file is the source of truth for architectural decisions. If a request
conflicts with it, flag the conflict instead of silently choosing.

---

## What EKS Event-Driven Autoscaling is

An EKS showcase: an asynchronous job-processing pipeline whose autoscaling is
the visible product. A user submits a batch of work through a web UI; jobs flow
through a queue; worker pods scale from **zero** on demand; nodes scale to fit
the pods; a dashboard shows queue depth, pod count, and node count live.

The goal is to demonstrate EKS competency, not to ship a real product. Favor
clarity and "demonstrably correct" over cleverness.

---

## Golden rules for Claude Code

1. **Never run `terraform apply` or `terraform destroy` yourself.** Generate
   code, run `fmt` / `validate` / `plan`, show me the plan, and wait. I apply.
2. **Work one phase at a time** (see Build Phases). Do not scaffold a later
   phase until the current one plans cleanly.
3. **No secrets in code.** No access keys, no account IDs hardcoded, no secrets
   in `.tf` or committed `.tfvars`. Use variables and `*.tfvars.example`.
4. **Pin versions.** Terraform, providers, Helm charts, and the Kubernetes
   version all get explicit version constraints.
5. When a `plan` errors, expect me to paste the error back. Debug from the
   actual error, not from assumptions about AWS state you can't see.

---

## Architecture decisions (do not silently change these)

| Area | Decision | Why |
|---|---|---|
| Node autoscaling | **Karpenter** (not Cluster Autoscaler) | Modern default; faster, bin-packs better |
| Pod autoscaling | **KEDA** with **scale-to-zero**, plus a plain **HPA** on one workload for contrast | The whole point of the demo |
| Pod IAM | **IRSA** (IAM Roles for Service Accounts) | No static keys anywhere |
| Ingress | **AWS Load Balancer Controller** → ALB | Standard, reviewable |
| Networking | **Single NAT Gateway** + S3 & ECR **VPC endpoints** | Cost: avoids per-AZ NAT and NAT data-processing on image pulls |
| GitOps | **Argo CD** pulls manifests from `gitops/` | Declarative, drift correction, audit trail |
| CI | **GitHub Actions** with **OIDC** federation to AWS (no long-lived keys) | CI-side equivalent of IRSA |
| Image scan | **Trivy** in CI before push to ECR | Security signal |
| Image tags | **Immutable, git-SHA tagged** (never `latest`) | Required for GitOps + rollbacks |
| Queue | **SQS** (optionally SNS→SQS fan-out) | KEDA scales on queue depth |
| Front door | **Lambda** validates requests / issues S3 presigned URLs | Justified serverless seam |

---

## Conventions

- **Region:** `us-east-1` (variable: `aws_region`, default set, overridable).
- **Naming:** the project/repo name is `eks-event-driven-autoscaling` (used for
  the Project tag and the state key). AWS/k8s resources use the short prefix
  **`eda`** plus the env to stay within name-length limits — e.g.
  `eda-dev-jobs` (SQS), `eda-dev` (cluster), namespace `eda`. Keep these
  distinct: don't use the long name as a resource prefix.
- **Tags:** every resource gets `Project=eda`, `Env`, `ManagedBy=terraform`.
- **Terraform:** `>= 1.7`. AWS provider `~> 5.x`. One module per concern under
  `infra/modules/`. Environments compose modules under `infra/environments/`.
- **State:** S3 backend + DynamoDB lock table, created by `infra/bootstrap`
  (which itself uses local state — that's expected and fine).
- **Kubernetes version:** pinned in the cluster module. Keep it on a CURRENT
  version — extended-support versions cost 6x on the control plane.
- **Helm-installed add-ons** (LB Controller, KEDA, Argo CD) live in the
  `platform` module via the `helm` provider, version-pinned.

---

## Repo layout

```
infra/
  bootstrap/            Phase 1: S3 state bucket + DynamoDB lock (local state)
  environments/dev/     Composes modules; holds backend.tf + tfvars
  modules/
    network/            Phase 2: VPC, subnets, single NAT, VPC endpoints
    cluster/            Phase 3: EKS, OIDC provider, IRSA base, Karpenter
    platform/           Phase 4: LB Controller, KEDA, Argo CD (Helm)
    app-resources/      Phase 5: SQS, SNS, S3, Lambda, ECR, app IRSA roles
app/
  web/                  nginx + static dashboard (front end)
  worker/               job processor (scaled by KEDA on SQS depth)
  lambda/               request validator / presigned-URL issuer
gitops/
  apps/                 Argo CD Application manifests
  manifests/            Deployments, ScaledObject, Ingress, HPA
.github/workflows/      infra.yml (TF plan/apply) + app.yml (build/scan/push)
```

---

## Build phases (dependency order)

Apply and verify each before starting the next.

1. **Bootstrap** — `infra/bootstrap`. State bucket + lock table. Apply by hand,
   then wire `environments/dev/backend.tf` to it.
2. **Network** — `modules/network`. VPC, public/private subnets across 2 AZs,
   ONE NAT gateway, S3 gateway endpoint, ECR + STS interface endpoints.
3. **Cluster** — `modules/cluster`. EKS control plane, IAM OIDC provider,
   Karpenter (controller + node IAM + provisioner/NodePool).
4. **Platform** — `modules/platform`. AWS Load Balancer Controller, KEDA,
   Argo CD — all via pinned Helm charts, all using IRSA where they need AWS.
5. **App resources** — `modules/app-resources`. SQS queue(s), SNS topic, S3
   bucket, Lambda + its role, ECR repos, and the IRSA roles that let the
   worker pods read SQS / write S3.
6. **App + GitOps** — build `app/*`, write `gitops/manifests/*` (worker
   Deployment, KEDA ScaledObject targeting SQS, nginx Deployment + Ingress,
   one HPA for contrast), and the Argo CD Application in `gitops/apps/`.

---

## Cost discipline

Running 24/7 is ~$130–210/mo. Treat `terraform apply` / `destroy` as the
on/off switch. Tear down cluster + NAT + nodes between sessions; keep only the
bootstrap state bucket. Standing it back up from code is itself part of the
demo (proves full reproducibility).

---

## Definition of done (for the showcase)

- `terraform apply` from clean brings up the whole stack.
- Submitting a batch in the UI drives worker pods 0 → N (visible in dashboard).
- Pods exceeding capacity triggers Karpenter to add a node; queue draining
  scales pods back toward 0 and Karpenter removes the empty node.
- A `git push` to `app/` triggers CI → ECR → image-tag bump → Argo CD sync.
- No static AWS credentials exist anywhere in the repo or cluster.
