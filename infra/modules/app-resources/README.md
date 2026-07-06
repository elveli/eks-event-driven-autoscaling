# Phase 5 — App-resources module

Everything outside the cluster that the app talks to, plus the IRSA wiring.

**Inputs:** `name_prefix`, `oidc_provider_arn`, `github_repo` (+ tunables:
`state_bucket_basename`, `lock_table_name`, `job_visibility_timeout`).
**Outputs:** `jobs_queue_url`, `jobs_queue_arn`, `bucket_name`,
`worker_role_arn`, `ecr_web_url`, `ecr_worker_url`, `lambda_function_url`,
`gha_role_arn`.

The `worker_role_arn` is what the worker's Kubernetes ServiceAccount annotates
for IRSA — that's how pods get SQS/S3 access with zero static credentials.
ECR repos are immutable-tag + scan-on-push.

## Implementation notes

- **Queue naming matters:** the KEDA operator's SQS-read policy (platform
  module) was pre-scoped to `<cluster_name>-*`, so the jobs queue MUST keep
  the `${name_prefix}-` prefix (`eda-dev-jobs`). Rename it and KEDA silently
  loses the ability to read queue depth.
- **DLQ:** messages that fail 3 receives land in `eda-dev-jobs-dlq` (14-day
  retention) instead of looping forever. No SNS topic — fan-out adds nothing
  to the 0→N→0 demo story (decided 2026-07-06).
- **Lambda deploys the stub:** `data.archive_file` zips `app/lambda/` as-is,
  so until Phase 6 implements the handler, invoking the Function URL returns
  a 502 (the stub raises `NotImplementedError`). That's expected — it proves
  the wiring. Phase 6's real handler redeploys automatically on the next
  apply via `source_code_hash`. `requirements.txt` is excluded from the zip:
  boto3 ships in the managed runtime.
- **Function URL, auth NONE:** deliberate demo tradeoff over API Gateway —
  one endpoint, no extra moving parts; the handler itself validates input.
- **Bucket CORS is required**, not optional: the dashboard uploads payloads
  with presigned PUT URLs straight from the browser, which is a cross-origin
  request. Public access stays fully blocked; presigned URLs carry their own
  auth.
- **ECR repos are NOT env-prefixed** (`eda-web`, `eda-worker`) unlike every
  other resource — images are env-agnostic and promoted by tag, so repos are
  shared across envs by design (matches the scaffold and the gitops
  manifests' expectations).
- **GitHub Actions OIDC** (`eda-gha` role) is the CI-side equivalent of IRSA:
  trust is scoped to `repo:<github_repo>:*`, permissions are ECR push (the
  two repos only) + `ReadOnlyAccess` + state-read/lock for `terraform plan`
  on PRs. Deliberately no apply-grade writes — applies stay manual per
  CLAUDE.md rule 1. The workflows should reference the role ARN via a GitHub
  Actions repository variable (`vars.AWS_ROLE_ARN`), never hardcoded —
  CLAUDE.md rule 3 forbids account IDs in committed files.
