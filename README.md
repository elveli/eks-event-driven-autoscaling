# EKS Event-Driven Autoscaling

An EKS showcase: an async job-processing pipeline whose autoscaling is the
visible product. Submit a batch → jobs hit SQS → worker pods scale **0→N** via
KEDA → Karpenter adds nodes when pods don't fit → a dashboard shows it live.

**KEDA** is a Kubernetes autoscaler that scales pods on external event
sources — here, SQS queue depth — instead of just CPU/memory, including down
to **zero** pods when the queue is empty. **Karpenter** is the node
autoscaler: instead of sizing fixed node groups, it provisions and removes
EC2 capacity directly to fit whatever's actually unschedulable, then
consolidates it away once it's idle.

The full architecture, conventions, and build phases are documented in
[`CLAUDE.md`](CLAUDE.md) — that file is the source of truth; this README is
the quick-start.

## Contents

- [Stack](#stack)
- [Architecture](#architecture)
- [Karpenter's role](#karpenters-role)
- [Workflow](#workflow)
- [Layout](#layout)
- [Build status](#build-status)
- [Operating the dev stack](#operating-the-dev-stack)
  - [Bring-up runbook](#bring-up-runbook)
  - [Driving the demo](#driving-the-demo)
  - [Make targets](#make-targets)
- [Cost discipline](#cost-discipline)
- [Guardrails already set](#guardrails-already-set)

## Stack

| Layer | Tool | Role |
|---|---|---|
| Provisioning | Terraform | Infra as code |
| Cluster | EKS | Managed Kubernetes control plane |
| Node autoscaling | Karpenter | Adds/removes EC2 capacity to fit unschedulable pods |
| Pod autoscaling | KEDA | Scales workers on SQS queue depth, down to **zero** |
| Pod autoscaling (contrast) | HPA | One plain CPU-based autoscaler, for contrast with KEDA |
| Pod identity | IRSA | AWS access via IAM roles — no static keys anywhere |
| Ingress | AWS Load Balancer Controller | Provisions the ALB from a Kubernetes Ingress |
| Queue | SQS + DLQ | Job queue KEDA watches, plus a dead-letter queue for failures |
| Front door | Lambda | Validates requests, issues S3 presigned URLs |
| GitOps | Argo CD | Syncs manifests from git; prunes and self-heals drift |
| CI/CD | GitHub Actions + OIDC + Trivy | Build → scan → push, no stored AWS keys |

## Architecture

Full target design — what's actually deployed is marked **done**; everything
else is annotated with the phase that builds it (see Build status below).
For the network view specifically (ingress path, namespaces, subnets/CIDRs,
egress routes), see the
[network diagram](https://htmlpreview.github.io/?https://github.com/elveli/eks-event-driven-autoscaling/blob/main/docs/network-diagram.html)
(renders [docs/network-diagram.html](docs/network-diagram.html) via
htmlpreview.github.io — the file itself is self-contained if you'd rather
open it locally).

```mermaid
flowchart TB
    User([User browser])
    GH([git push to app/])

    subgraph Net["Network — done"]
        ALB["ALB (phase 4)"]
        NAT["NAT Gateway ×1"]
        VPCE["VPC endpoints: S3, ECR api/dkr, STS"]
    end

    subgraph Cluster["EKS eda-dev — done"]
        SysNG["System node group (2× t3.medium)"]
        Karpenter["Karpenter controller"]
        KarpNodes["Karpenter spot nodes (dynamic)"]
        LBC["AWS LB Controller (phase 4)"]
        KEDA["KEDA (phase 4)"]
        ArgoCD["Argo CD (phase 4)"]
        WebPod["nginx dashboard (phase 6)"]
        WorkerPod["worker pods (phase 6)"]
    end

    subgraph AppRes["App resources — phase 5"]
        SQS[("SQS queue")]
        S3B[("S3 bucket")]
        Lambda{{"Lambda validator"}}
        ECR[("ECR repos")]
    end

    subgraph Boot["Bootstrap — done"]
        StateS3[("S3 state bucket")]
        StateDDB[("DynamoDB lock table")]
    end

    subgraph CICD["CI/CD — phase 6"]
        Actions["GitHub Actions + OIDC"]
        Trivy["Trivy image scan"]
    end

    IAM["IAM OIDC provider + IRSA roles — done"]

    User -->|HTTPS| ALB --> WebPod
    WebPod --> Lambda
    Lambda --> S3B
    Lambda --> SQS
    KEDA -->|poll queue depth| SQS
    KEDA -->|scale 0..N| WorkerPod
    WorkerPod --> SQS
    WorkerPod --> S3B
    Karpenter -. provisions .-> KarpNodes
    KarpNodes -. hosts .-> WorkerPod
    LBC -. manages .-> ALB
    ArgoCD -. syncs manifests .-> Cluster
    IAM -. federates .-> Karpenter

    GH --> Actions --> Trivy --> ECR
    Actions -. bumps tag, commits to gitops/ .-> ArgoCD
```

## Karpenter's role

Two node pools exist side by side, and they're not interchangeable:

- **System node group** — a small, static, EKS-managed node group (2×
  t3.medium). It exists only to run the platform's own pods: the Karpenter
  controller itself, KEDA, the AWS Load Balancer Controller, Argo CD. No
  worker or dashboard pod ever lands here.
- **Karpenter-provisioned nodes** — dynamic EC2 capacity that exists only
  while worker pods need it. Every worker pod runs here, nowhere else.

Karpenter's whole job is managing that second pool, on a loop:

1. **Watches for unschedulable pods**, not queue depth or any metric. When
   KEDA scales workers 0→N faster than the system node group has room, those
   pods go `Pending`; Karpenter reacts to that directly.
2. **Picks and launches instances via a NodePool + EC2NodeClass** (CRDs
   applied in `infra/modules/cluster/main.tf`, `kubectl_manifest.karpenter_node_pool`)
   — spot or on-demand, `c`/`m`/`r` families, generation > 2, amd64/linux
   only. It picks the cheapest shape that fits the pending pods; there's no
   fixed instance type to configure.
3. **Caps total capacity at 100 vCPU** (`NodePool.spec.limits.cpu`) — a
   runaway-cost guardrail so one oversized batch submission can't blow the
   demo budget.
4. **Consolidates aggressively**: `consolidationPolicy: WhenEmptyOrUnderutilized`,
   `consolidateAfter: 1m`. Once the queue drains and pods scale back to 0,
   Karpenter terminates the now-idle nodes about a minute later — this is the
   "nodes scale back down" half of the demo.
5. **Force-recycles nodes every 30 days** (`expireAfter: 720h`) even if
   they're busy, so long-lived nodes don't drift onto a stale AMI. The node
   class resolves AMIs via the `al2023@latest` alias — fine for short-lived
   demo nodes, but Karpenter's own docs call this out as unsuitable for
   production (an AMI release silently replaces running nodes).
6. **Drains gracefully on spot interruption.** An SQS queue + EventBridge
   rules feed AWS's spot-interruption / rebalance / instance-state-change /
   health-event notifications to Karpenter, so it cordons and evicts before
   an instance is actually reclaimed, instead of the pod just vanishing.

IAM-wise Karpenter needs two separate roles: an **IRSA role for the
controller** (EC2/IAM/EKS API calls) and a plain **EC2 instance role for the
nodes it launches** (`KarpenterNodeRole-*`). The node role isn't part of an
EKS-managed node group, so it needs its own explicit EKS access entry — see
`infra/modules/cluster/README.md` for why that has to be an `EC2_LINUX`
entry, not `STANDARD`.

One consequence worth knowing: the Karpenter controller runs on the system
node group, not on capacity it manages itself — so anything that pauses the
system node group (e.g. a future scale-to-zero kill switch) takes Karpenter
down with it too.

## Workflow

The two flows that make up "the demo": a user submitting a batch (runtime,
event-driven autoscaling) and a developer pushing code (CI/CD). Both are
target-state — phases 4–6 build the pieces these flows depend on.

**Submitting a batch — pods and nodes scale 0→N→0:**

```mermaid
sequenceDiagram
    actor User
    participant Web as nginx dashboard
    participant Lambda
    participant S3
    participant SQS
    participant KEDA
    participant Worker as worker pods
    participant Karpenter
    participant EC2 as EC2 (spot nodes)

    User->>Web: Submit batch (N jobs × S seconds)
    opt payload attached
        Web->>Lambda: POST /api/presign
        Lambda-->>Web: presigned PUT URL
        Web->>S3: Upload payload (direct, presigned)
    end
    Web->>Lambda: POST /api/submit
    Lambda->>SQS: Enqueue N job messages
    loop every poll interval
        KEDA->>SQS: Check queue depth
    end
    KEDA->>Worker: Scale 0 -> N pods
    Worker->>Karpenter: Pod unschedulable (no capacity)
    Karpenter->>EC2: Launch spot node(s)
    Worker->>SQS: Consume + process job
    Worker->>S3: Write result
    Web->>Lambda: GET /api/stats (queue depth)
    Web->>User: Live queue depth / pod count / node count
    Note over SQS,Worker: Queue drains as jobs complete
    KEDA->>Worker: Scale N -> 0
    Karpenter->>EC2: Consolidate + terminate empty nodes
```

**Pushing code — image build to GitOps sync:**

```mermaid
flowchart LR
    Dev["git push to app/"] --> Actions["GitHub Actions\n(OIDC to AWS, no static keys)"]
    Actions --> Trivy["Trivy image scan"]
    Trivy -->|pass| ECR["Push to ECR\n(immutable, git-SHA tag)"]
    ECR --> Bump["Bump image tag\nin gitops/manifests"]
    Bump --> Repo["Commit to gitops/"]
    Repo --> ArgoCDSync["Argo CD detects drift"]
    ArgoCDSync --> ClusterSync["Sync to EKS"]
```

## Layout

```
.
├── .github/workflows/          infra.yml (fmt/validate/plan) + app.yml (build/scan/push/bump)
├── Makefile                    wrappers for every command below (`make help`)
├── app/
│   ├── lambda/                 request validator / presigned-URL issuer
│   ├── web/                    nginx + dashboard + cluster-stats sidecar
│   └── worker/                 job processor, scaled by KEDA on SQS depth
├── gitops/
│   ├── apps/                   Argo CD Application manifests
│   └── manifests/              Deployments, ScaledObject, Ingress, HPA
├── infra/
│   ├── bootstrap/              phase 1: state bucket + lock table (local state)
│   ├── environments/dev/       composes modules; backend + tfvars + on/off script
│   └── modules/
│       ├── network/            phase 2: VPC, subnets, single NAT, VPC endpoints
│       ├── cluster/            phase 3: EKS, OIDC, IRSA, Karpenter
│       ├── platform/            phase 4: LB Controller, KEDA, Argo CD (Helm)
│       └── app-resources/       phase 5: SQS, S3, Lambda, ECR, app IRSA
├── CLAUDE.md                   architecture decisions, build phases, conventions
└── README.md
```

Each module and app folder has its own `README.md` describing exactly what
goes in it.

## Build status

| Phase | What | Status |
|---|---|---|
| 1 | Bootstrap (state bucket + lock table) | ✅ applied |
| 2 | Network (VPC, single NAT, VPC endpoints) | ✅ applied |
| 3 | Cluster (EKS, OIDC/IRSA, Karpenter) | ✅ applied |
| 4 | Platform (LB Controller, KEDA, Argo CD) | 🧩 code complete, plans clean — awaiting apply |
| 5 | App resources (SQS, S3, Lambda, ECR, app IRSA, CI OIDC) | 🧩 code complete, plans clean — awaiting apply |
| 6 | App + GitOps (worker, dashboard, ScaledObject, CI) | 🧩 code complete — awaiting apply + first CI run |

All six phases are code complete. What remains is operational: apply, run CI
once to populate ECR, hand the manifests to Argo CD (the bring-up runbook
below), and verify the definition of done in `CLAUDE.md`.

## Operating the dev stack

Every command below has a `make` wrapper (run `make help` for the menu; each
target is also runnable by hand). The lifecycle targets go through
`infra/environments/dev/manage-aws-dev-stack.sh`, which is scoped to that
directory only — it never touches `infra/bootstrap`, so the state bucket and
lock table stay up between sessions.

### Bring-up runbook

Clean AWS account → running demo, in order:

```sh
make apply       # 1. terraform: VPC + EKS + Karpenter + platform + app resources (~20 min)
make kubeconfig  # 2. point kubectl at the cluster
make ci-var      # 3. give GitHub Actions the CI role ARN (repo variable AWS_ROLE_ARN)
make ci-run      # 4. build + Trivy-scan + push images, pin tags in gitops/ (watches the run)
make gitops      # 5. point Argo CD at gitops/manifests/ — one-time, it auto-syncs after this
make url         # 6. the dashboard's ALB address (takes ~2 min to provision)
```

Order matters at two points: CI needs the `eda-gha` role and ECR repos
(step 1) plus the `AWS_ROLE_ARN` variable (step 3) before it can push;
once Argo CD is pointed at the repo (step 5) it deploys whatever image tags
CI pinned in `gitops/manifests/kustomization.yaml` (step 4), so until CI has
run once there is nothing deployable.

If the first `apply` errors reaching the cluster (Karpenter Helm release /
NodePool manifests), that's the known first-apply chicken-and-egg case in
`infra/modules/cluster/README.md` — re-run `apply` once.

### Driving the demo

Open the dashboard (`make url`) and submit a batch — or from the terminal:

```sh
make submit N=100 DUR=20   # enqueue 100 jobs of ~20s each via the Lambda
make watch                 # queue depth, worker pods, nodes — live, every 2s
```

What you should see: queue depth jumps to 100 → KEDA scales the worker
0→20 (one pod per 5 queued jobs) → pods exceed spare capacity → Karpenter
launches spot node(s) → the queue drains → pods scale back to 0 → Karpenter
consolidates the empty nodes away. The dashboard shows all of it; so does
`make watch`.

Everything else worth poking at is in the [make targets](#make-targets) table
below.

### Make targets

`make help` prints this same menu in the terminal. Defaults for the
parameterized target: `make submit` enqueues `N=50` jobs of `DUR=15` seconds.

| Target | What it does |
|---|---|
| **Lifecycle** — via `manage-aws-dev-stack.sh`, never touches `infra/bootstrap` | |
| `make plan` | terraform plan |
| `make apply` | provision VPC + EKS + Karpenter + platform + app resources (~20 min) |
| `make destroy` | the cost kill switch: tear it all down (state bucket survives) |
| `make kubeconfig` | point kubectl at the cluster |
| **CI / GitOps bootstrap** — once per bring-up, in this order | |
| `make ci-var` | give GitHub Actions the CI role ARN (repo variable `AWS_ROLE_ARN`) |
| `make ci-run` | build + Trivy-scan + push images, pin tags in gitops/ (watches the run) |
| `make gitops` | one-time: creates the Argo CD Application resource pointing at `gitops/manifests/`, so it starts auto-syncing from git |
| **Driving the demo** | |
| `make url` | the dashboard's ALB address (empty until the LB controller provisions it) |
| `make submit N=100 DUR=20` | enqueue a batch straight at the Lambda |
| `make watch` | the whole story every 2s: queue depth, worker pods, nodes |
| `make stats` | queue depth as the dashboard sees it (via the Lambda) |
| **Poking at state** | |
| `make queue` | raw SQS attributes of the jobs queue |
| `make dlq` | anything in the dead-letter queue? (3 failed attempts land here) |
| `make purge` | drop every queued job (in-flight ones finish; pods then drain to 0) |
| `make results` | worker output objects in S3, newest last + total count |
| `make pods` | every pod in the cluster, with the node it runs on |
| `make nodes` | nodes with their provenance (system node group vs Karpenter) |
| `make nodegroups` | node capacity, both kinds: static system group + Karpenter pool/claims |
| `make scaling` | both autoscalers side by side: KEDA ScaledObject + plain HPA |
| `make logs-worker` | follow all worker logs (one JSON line per job event) |
| `make logs-lambda` | follow the front-door Lambda's logs |
| `make logs-karpenter` | follow Karpenter's logs (node provisioning/consolidation decisions) |
| `make logs-keda` | follow KEDA's logs (operator + admission webhook + metrics apiserver, prefixed) |
| `make argocd` | Argo CD UI on localhost:8080 (prints the admin password) |
| `make irsa` | service accounts annotated with IAM roles — the AWS-access wiring |
| **Health gate** — pass/fail, exits 1 on any failure | |
| `make healthchecks` | Argo CD sync/health, Deployment readiness (spec vs ready replicas), ALB target-group health |
| `make inventory` | leak check: `Project=eda` resources (cross-verified live, not just the tagging index) + controller-created orphans (after destroy: only the bootstrap pair) |

## Cost discipline

Running 24/7 is ~$130–210/mo. Use `make apply` / `make destroy` as your on/off
switch — tear down the cluster, NAT, and nodes between sessions; keep only the
bootstrap state bucket. Re-applying from code is part of the demo (proves
reproducibility). `make inventory` should list nothing after a destroy.

## Guardrails already set

- `.claude/settings.json` lets Claude run read-only/plan commands freely but
  makes it **ask** before `apply`, `destroy`, `kubectl apply`, or `aws *`.
- `.claudeignore` / `.gitignore` keep state files and `*.tfvars` out of context
  and out of git.
