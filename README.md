# BurstLab

An EKS showcase: an async job-processing pipeline whose autoscaling is the
visible product. Submit a batch → jobs hit SQS → worker pods scale **0→N** via
KEDA → Karpenter adds nodes when pods don't fit → a dashboard shows it live.

This repo is a **scaffold**. The structure, decisions, and per-folder TODOs are
in place; the resource bodies are not. Point Claude Code at it and build phase
by phase.

## Stack

Terraform · EKS · Karpenter (nodes) · KEDA scale-to-zero + one HPA (pods) ·
IRSA (no static keys) · AWS Load Balancer Controller (ALB) · SQS/SNS · Lambda ·
Argo CD (GitOps) · GitHub Actions + OIDC + Trivy (CI/CD).

## Layout

- `infra/bootstrap` — remote-state bucket + lock table (phase 1, local state)
- `infra/environments/dev` — composes modules; backend + tfvars
- `infra/modules/{network,cluster,platform,app-resources}` — phases 2–5
- `app/{web,worker,lambda}` — nginx dashboard, job processor, front-door Lambda
- `gitops/{apps,manifests}` — Argo CD Application + k8s manifests
- `.github/workflows` — `infra.yml`, `app.yml`

Each module and folder has a `README.md` describing exactly what goes in it.
The full plan lives in `CLAUDE.md`.

## First session with Claude Code

1. Open this folder in VS Code; open the Claude Code panel.
2. Confirm it has read `CLAUDE.md` (ask: *"summarize the build phases and the
   golden rules from CLAUDE.md"*).
3. Start phase 1: *"Implement `infra/bootstrap/main.tf` per its TODOs and
   README. Run fmt and validate. Don't apply — show me the plan."*
4. You run `terraform apply` in the integrated terminal once the plan looks
   right. Wire `environments/dev/backend.tf` to the outputs.
5. Move to phase 2 only when phase 1 is applied and verified. Repeat.

## Cost discipline

Running 24/7 is ~$130–210/mo. Use `terraform apply`/`destroy` as your on/off
switch — tear down the cluster, NAT, and nodes between sessions; keep only the
bootstrap state bucket. Re-applying from code is part of the demo.

## Guardrails already set

- `.claude/settings.json` lets Claude run read-only/plan commands freely but
  makes it **ask** before `apply`, `destroy`, `kubectl apply`, or `aws *`.
- `.claudeignore` / `.gitignore` keep state files and `*.tfvars` out of context
  and out of git.
