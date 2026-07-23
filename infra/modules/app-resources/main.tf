# Phase 5 — Application AWS resources
# Everything outside the cluster the app talks to: the jobs queue KEDA scales
# on, the payload/results bucket, the front-door Lambda, the ECR repos CI
# pushes to, and the IRSA + CI OIDC roles that make it all work without a
# single static credential.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  oidc_provider_host = trimprefix(
    var.oidc_provider_arn,
    "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/"
  )
  # Account-id suffix for global uniqueness, same trick as the bootstrap
  # state bucket. Derived, not hardcoded (no account IDs in code).
  bucket_name       = "${var.name_prefix}-jobs-${data.aws_caller_identity.current.account_id}"
  state_bucket_name = "${var.state_bucket_basename}-${data.aws_caller_identity.current.account_id}"

  # An IAM OIDC provider's ARN is fully deterministic from partition + account
  # + issuer URL (no random suffix) — same derivation whether this module
  # creates the resource or reuses one created by another project sharing
  # the account (see var.create_github_oidc_provider).
  github_oidc_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

# ---- SQS: jobs queue + dead-letter queue ----
# KEDA scales the worker on the depth of the jobs queue. Messages that fail
# processing 3 times land in the DLQ instead of looping forever.

resource "aws_sqs_queue" "jobs_dlq" {
  name                    = "${var.name_prefix}-jobs-dlq"
  sqs_managed_sse_enabled = true

  # Give poison messages time to be inspected before they age out.
  message_retention_seconds = 1209600 # 14 days (max)
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${var.name_prefix}-jobs"
  sqs_managed_sse_enabled    = true
  visibility_timeout_seconds = var.job_visibility_timeout

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 3
  })
}

# ---- S3: job payloads / results ----

resource "aws_s3_bucket" "jobs" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_public_access_block" "jobs" {
  bucket = aws_s3_bucket.jobs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "jobs" {
  bucket = aws_s3_bucket.jobs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# The dashboard uploads payloads straight to S3 with presigned PUT URLs
# issued by the Lambda — that's a cross-origin browser request, so the
# bucket needs CORS. Public access stays blocked; presigned URLs carry
# their own auth.
resource "aws_s3_bucket_cors_configuration" "jobs" {
  bucket = aws_s3_bucket.jobs.id

  cors_rule {
    allowed_methods = ["PUT", "GET"]
    allowed_origins = ["*"] # demo: the ALB hostname isn't known at plan time
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

# ---- Lambda: front-door (validator / presigned-URL issuer) ----
# Deploys whatever is in app/lambda/ right now — a NotImplementedError stub
# until Phase 6. source_code_hash means the real handler redeploys on the
# next apply after Phase 6 lands, with no module changes.

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../../app/lambda"
  output_path = "${path.module}/.terraform-lambda.zip"
  excludes    = ["requirements.txt"] # boto3 ships in the Lambda runtime
}

resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-front-door-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_app" {
  name = "AppAccessPolicy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowEnqueueAndStats"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.jobs.arn
      },
      {
        # Presigned URLs act with the signer's permissions — the Lambda
        # needs PutObject/GetObject for the URLs it issues to work.
        Sid      = "AllowPresignedObjectAccess"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.jobs.arn}/*"
      },
    ]
  })
}

resource "aws_lambda_function" "front_door" {
  function_name    = "${var.name_prefix}-front-door"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.jobs.url
      BUCKET    = aws_s3_bucket.jobs.bucket
    }
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_logs]
}

# Function URL instead of API Gateway — one endpoint, no extra moving parts.
# auth NONE is a deliberate demo tradeoff; the handler itself validates input.
resource "aws_lambda_function_url" "front_door" {
  function_name      = aws_lambda_function.front_door.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST"]
    allow_headers = ["content-type"]
    max_age       = 3000
  }
}

# authorization_type = "NONE" above only skips SigV4 signing — Lambda still
# requires an explicit resource policy granting invoke access, or every
# caller (including the dashboard's own /api/ proxy) gets 403 Forbidden.
# Two statements are required (AWS changed this for function URLs created
# after Oct 2025, docs.aws.amazon.com/lambda/latest/dg/urls-auth.html):
# lambda:InvokeFunctionUrl passes the function-URL auth check, but the
# actual invocation also needs a separate lambda:InvokeFunction grant.
resource "aws_lambda_permission" "front_door_public_url" {
  statement_id           = "AllowPublicInvokeFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.front_door.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# AWS's own console/CLI scope this second grant to function-URL calls only
# via an InvokedViaFunctionUrl condition (lambda:InvokeFunction otherwise
# also works through the plain Invoke API). The Terraform argument for that,
# invoked_via_function_url, only landed in AWS provider v6.28.0
# (hashicorp/terraform-provider-aws#44858) — this repo is pinned to `~> 5.0`,
# so the grant below is unconditional. Acceptable here: the function URL is
# already intentionally public (see the auth-NONE comment above); revisit if
# this module ever bumps to provider v6.
resource "aws_lambda_permission" "front_door_public_invoke" {
  statement_id  = "AllowPublicInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.front_door.function_name
  principal     = "*"
}

# ---- ECR: image repos ----
# Not env-prefixed (unlike everything else): images are env-agnostic and
# promoted by tag, so the repos are shared across envs by design.

resource "aws_ecr_repository" "repos" {
  for_each = toset(["eda-web", "eda-worker"])

  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # git-SHA tags, never overwritten
  # Without this, `terraform destroy` errors with "repository not empty"
  # whenever CI has pushed images since the last teardown — hit this for
  # real on 2026-07-11 and worked around it by hand. Acceptable here: these
  # are CI-rebuildable image tags, not data.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ---- Worker IRSA role ----
# What the eda-worker ServiceAccount (namespace eda) annotates with
# eks.amazonaws.com/role-arn. Consume jobs, write results — nothing else.

resource "aws_iam_role" "worker" {
  name = "${var.name_prefix}-worker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_provider_host}:sub" = "system:serviceaccount:eda:eda-worker"
          "${local.oidc_provider_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "worker" {
  name = "JobProcessingPolicy"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowConsumeJobs"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.jobs.arn
      },
      {
        Sid      = "AllowResultReadWrite"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.jobs.arn}/*"
      },
    ]
  })
}

# ---- GitHub Actions OIDC federation (CI-side equivalent of IRSA) ----
# Lets .github/workflows assume a role with short-lived credentials — no
# stored AWS keys in GitHub. thumbprint_list omitted for the same reason as
# the cluster module's EKS provider: AWS derives trust from the provider's
# own certificate chain.
#
# AWS allows only ONE IAM OIDC provider per issuer URL per account, and this
# issuer (token.actions.githubusercontent.com) is GitHub's single global
# token issuer — every GitHub-hosted repo's Actions workflows present the
# same URL, so an AWS account that hosts more than one project's CI can only
# have one such provider, created by whichever project applies first.
# var.create_github_oidc_provider lets a later project reuse it instead of
# hitting EntityAlreadyExists.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "gha" {
  name = "eda-gha" # the exact name both workflows already reference

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.github_oidc_arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
      }
    }]
  })
}

# app.yml: build -> scan -> push. GetAuthorizationToken can't be
# resource-scoped; the push actions are limited to the two repos.
resource "aws_iam_role_policy" "gha_ecr_push" {
  name = "EcrPushPolicy"
  role = aws_iam_role.gha.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowEcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "AllowPushToAppRepos"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [for r in aws_ecr_repository.repos : r.arn]
      },
    ]
  })
}

# infra.yml: terraform plan on PRs. ReadOnlyAccess covers the refresh reads;
# the inline policy adds state read + lock-table access. Deliberately NO
# write permissions beyond the lock — applies stay manual (CLAUDE.md rule 1).
resource "aws_iam_role_policy_attachment" "gha_readonly" {
  role       = aws_iam_role.gha.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "gha_tf_plan" {
  name = "TerraformPlanPolicy"
  role = aws_iam_role.gha.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowStateRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:s3:::${local.state_bucket_name}",
          "arn:${data.aws_partition.current.partition}:s3:::${local.state_bucket_name}/*",
        ]
      },
      {
        Sid      = "AllowStateLock"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:${data.aws_partition.current.partition}:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.lock_table_name}"
      },
    ]
  })
}
