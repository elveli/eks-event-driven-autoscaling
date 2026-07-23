# Phase 4 — Platform add-ons (all via pinned Helm charts)
# AWS Load Balancer Controller (ALB ingress), KEDA (event-driven pod scaling),
# and Argo CD (GitOps sync) — each gets IRSA where it needs AWS access. The
# helm/kubernetes providers are the ones configured in environments/dev/main.tf
# against the cluster module's own outputs.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  oidc_provider_host = trimprefix(
    var.oidc_provider_arn,
    "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/"
  )
}

# ---- AWS Load Balancer Controller ----

resource "aws_iam_role" "lb_controller" {
  name = "${var.cluster_name}-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_provider_host}:sub" = "system:serviceaccount:${var.lb_controller_namespace}:aws-load-balancer-controller"
          "${local.oidc_provider_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# The exact document AWS's own install instructions point at:
# https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
# Vendored under policies/ rather than hand-transcribed — it's long and any
# dropped statement would surface as a hard-to-debug ALB provisioning failure.
resource "aws_iam_policy" "lb_controller" {
  name   = "${var.cluster_name}-lb-controller"
  policy = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "helm_release" "lb_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = var.lb_controller_version
  namespace        = var.lb_controller_namespace
  create_namespace = false # kube-system already exists

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  set {
    name  = "region"
    value = data.aws_region.current.name
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.lb_controller.arn
  }

  depends_on = [aws_iam_role_policy_attachment.lb_controller]
}

# ---- KEDA ----
# Only the operator needs AWS access (to read SQS queue depth for the
# aws-sqs-queue scaler with identityOwner: operator); the metrics-server and
# webhook components don't call AWS APIs.

resource "aws_iam_role" "keda" {
  name = "${var.cluster_name}-keda-operator"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.oidc_provider_host}:sub" = "system:serviceaccount:${var.keda_namespace}:keda-operator"
          "${local.oidc_provider_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "keda_sqs_read" {
  name = "SQSReadPolicy"
  role = aws_iam_role.keda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSQSQueueAttributesRead"
        Effect = "Allow"
        Action = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        # Scoped by the naming convention app-resources (Phase 5) will use
        # (eda-<env>-*) even though those queues don't exist yet — IAM
        # doesn't require the resource to exist for the ARN to be valid.
        Resource = "arn:${data.aws_partition.current.partition}:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${var.cluster_name}-*"
      },
      {
        Sid    = "AllowCloudWatchRead"
        Effect = "Allow"
        # CloudWatch metric-read actions don't support resource-level scoping.
        Action   = ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics"]
        Resource = "*"
      },
    ]
  })
}

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.keda_version
  namespace        = var.keda_namespace
  create_namespace = true

  set {
    name  = "podIdentity.aws.irsa.enabled"
    value = "true"
  }

  set {
    name  = "podIdentity.aws.irsa.roleArn"
    value = aws_iam_role.keda.arn
  }

  # The LB Controller's MutatingWebhookConfiguration intercepts EVERY Service
  # object cluster-wide (KEDA's charts create several), not just ones it
  # provisions ALBs for. Without this dependency, Terraform applies both
  # helm_releases in parallel and KEDA's Service creation can hit the webhook
  # before the controller's pods are up — "no endpoints available" — failing
  # the release on a fresh cluster. helm_release's default wait=true makes
  # this depends_on actually wait for ready pods, not just "helm install
  # returned".
  depends_on = [aws_iam_role_policy.keda_sqs_read, helm_release.lb_controller]
}

# ---- Argo CD ----
# No AWS API calls, so no IRSA role. Access is via
# `kubectl port-forward svc/argocd-server -n argocd 8080:443` and the
# argocd-initial-admin-secret Secret for now — no Ingress is planned for the
# Argo CD UI itself (CLAUDE.md scopes the ALB to the app, not the platform).

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  namespace        = var.argocd_namespace
  create_namespace = true

  # Same LB Controller webhook race as keda above — argocd-server's Service
  # is subject to the same cluster-wide mutating webhook.
  depends_on = [helm_release.lb_controller]
}

# ---- metrics-server ----
# The standard Kubernetes resource-metrics pipeline (metrics.k8s.io) — not to
# be confused with KEDA's own bundled "metrics server" component mentioned
# above, which only serves KEDA's external/custom metrics (e.g. SQS depth).
# This is what `kubectl top nodes/pods` reads, and what the plain
# eda-web HPA (a CPU target) needs to work at all — without it the HPA has no
# metrics source and just sits on "<unknown>". No AWS API calls, so no IRSA.

resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  version          = var.metrics_server_version
  namespace        = var.metrics_server_namespace
  create_namespace = false # kube-system already exists

  # Same LB Controller webhook race as keda/argocd above — this chart's
  # Service is subject to the same cluster-wide mutating webhook.
  depends_on = [helm_release.lb_controller]
}
