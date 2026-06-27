# Phase 3 — Cluster
# EKS control plane + IAM OIDC provider (IRSA foundation) + a tiny static
# managed node group for system pods + Karpenter for real worker capacity.

terraform {
  required_providers {
    kubectl = { source = "gavinbunney/kubectl" }
  }
}
#
# NOTE on first apply: the kubernetes/helm/kubectl providers (configured in
# environments/dev/main.tf) authenticate against this cluster's endpoint,
# which doesn't exist until aws_eks_cluster.main is created in this same
# apply. This is a well-known Terraform chicken-and-egg case — if the first
# apply errors trying to reach the cluster for the Karpenter helm_release or
# the NodePool/EC2NodeClass manifests, just re-run `terraform apply` once the
# cluster exists. Subsequent applies are unaffected.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  cluster_name = var.name_prefix
}

# ---- Control plane ----

resource "aws_iam_role" "cluster" {
  name = "${var.name_prefix}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.k8s_version

  vpc_config {
    subnet_ids = var.subnet_ids
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# ---- IAM OIDC provider (IRSA foundation) ----
# thumbprint_list is intentionally omitted: AWS derives trust from the
# provider's own certificate, not a pinned thumbprint (see AWS provider docs
# for aws_iam_openid_connect_provider).

resource "aws_iam_openid_connect_provider" "this" {
  url            = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  oidc_provider_host = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}

# ---- System node group ----
# Small, fixed-size, managed node group that only hosts platform pods
# (Karpenter, KEDA, Argo CD, LB Controller). Real worker pods land on
# Karpenter-provisioned capacity, not here.

resource "aws_iam_role" "system_node" {
  name = "${var.name_prefix}-system-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "system_node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
    "AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.system_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value}"
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.name_prefix}-system"
  node_role_arn   = aws_iam_role.system_node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.system_node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.system_node_count
    min_size     = var.system_node_count
    max_size     = var.system_node_count
  }

  labels = {
    role = "system"
  }

  depends_on = [aws_iam_role_policy_attachment.system_node]
}

# ---- Karpenter: node IAM role ----
# Separate from the system node group's role: EKS managed node groups get an
# automatic access entry, but Karpenter-launched instances don't belong to a
# managed node group, so they need their own role + a manual access entry.

resource "aws_iam_role" "karpenter_node" {
  name = "KarpenterNodeRole-${local.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "AmazonEKS_CNI_Policy",
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value}"
}

# EC2_LINUX access entries don't take kubernetes_groups — the
# system:bootstrappers/system:nodes mapping is implicit for this type and a
# STANDARD entry can't use system:-prefixed group names (AWS rejects it).
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# ---- Karpenter: controller IAM role (IRSA) ----

resource "aws_iam_role" "karpenter_controller" {
  name = "${var.name_prefix}-karpenter-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = aws_iam_openid_connect_provider.this.arn
      }
      Condition = {
        StringEquals = {
          "${local.oidc_provider_host}:sub" = "system:serviceaccount:${var.karpenter_namespace}:karpenter"
          "${local.oidc_provider_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# Controller IAM policies, transcribed from the official Karpenter
# CloudFormation template (aws/karpenter-provider-aws, getting-started).
# ZonalShiftPolicy is intentionally omitted — zonal autoshift isn't in scope
# for this single-region demo.

resource "aws_iam_role_policy" "karpenter_node_lifecycle" {
  name = "NodeLifecyclePolicy"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceAccessActions"
        Effect = "Allow"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}::image/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}::snapshot/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:security-group/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:subnet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:capacity-reservation/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:placement-group/*",
        ]
        Action = ["ec2:RunInstances", "ec2:CreateFleet"]
      },
      {
        Sid      = "AllowScopedEC2LaunchTemplateAccessActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:launch-template/*"
        Action   = ["ec2:RunInstances", "ec2:CreateFleet"]
        Condition = {
          StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}" = "owned" }
          StringLike   = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" }
        }
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:spot-instances-request/*",
        ]
        Action = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${local.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                        = local.cluster_name
          }
          StringLike = { "aws:RequestTag/karpenter.sh/nodepool" = "*" }
        }
      },
      {
        Sid    = "AllowScopedResourceCreationTagging"
        Effect = "Allow"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:spot-instances-request/*",
        ]
        Action = "ec2:CreateTags"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${local.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                        = local.cluster_name
            "ec2:CreateAction"                                           = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
          }
          StringLike = { "aws:RequestTag/karpenter.sh/nodepool" = "*" }
        }
      },
      {
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:instance/*"
        Action   = "ec2:CreateTags"
        Condition = {
          StringEquals                = { "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}" = "owned" }
          StringLike                  = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" }
          StringEqualsIfExists        = { "aws:RequestTag/eks:eks-cluster-name" = local.cluster_name }
          "ForAllValues:StringEquals" = { "aws:TagKeys" = ["eks:eks-cluster-name", "karpenter.sh/nodeclaim", "Name"] }
        }
      },
      {
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:*:launch-template/*",
        ]
        Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
        Condition = {
          StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}" = "owned" }
          StringLike   = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "karpenter_iam_integration" {
  name = "IAMIntegrationPolicy"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Resource = aws_iam_role.karpenter_node.arn
        Action   = "iam:PassRole"
        Condition = {
          StringEquals = { "iam:PassedToService" = ["ec2.amazonaws.com", "ec2.amazonaws.com.cn"] }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileCreationActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Action   = ["iam:CreateInstanceProfile"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${local.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                        = local.cluster_name
            "aws:RequestTag/topology.kubernetes.io/region"               = data.aws_region.current.name
          }
          StringLike = { "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*" }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileTagActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Action   = ["iam:TagInstanceProfile"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"               = data.aws_region.current.name
            "aws:RequestTag/kubernetes.io/cluster/${local.cluster_name}"  = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                         = local.cluster_name
            "aws:RequestTag/topology.kubernetes.io/region"                = data.aws_region.current.name
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"  = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Action   = ["iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"               = data.aws_region.current.name
          }
          StringLike = { "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*" }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "karpenter_eks_integration" {
  name = "EKSIntegrationPolicy"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AllowAPIServerEndpointDiscovery"
      Effect   = "Allow"
      Resource = aws_eks_cluster.main.arn
      Action   = "eks:DescribeCluster"
    }]
  })
}

resource "aws_iam_role_policy" "karpenter_interruption" {
  name = "InterruptionPolicy"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AllowInterruptionQueueActions"
      Effect   = "Allow"
      Resource = aws_sqs_queue.karpenter_interruption.arn
      Action   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
    }]
  })
}

resource "aws_iam_role_policy" "karpenter_resource_discovery" {
  name = "ResourceDiscoveryPolicy"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowRegionalReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action = [
          "ec2:DescribeCapacityReservations",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribePlacementGroups",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
        ]
        Condition = {
          StringEquals = { "aws:RequestedRegion" = data.aws_region.current.name }
        }
      },
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}::parameter/aws/service/*"
        Action   = "ssm:GetParameter"
      },
      {
        Sid      = "AllowPricingReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action   = "pricing:GetProducts"
      },
      {
        Sid      = "AllowUnscopedInstanceProfileListAction"
        Effect   = "Allow"
        Resource = "*"
        Action   = "iam:ListInstanceProfiles"
      },
      {
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Action   = "iam:GetInstanceProfile"
      },
    ]
  })
}

# ---- Karpenter: interruption queue + EventBridge rules ----
# Lets Karpenter drain nodes gracefully on spot interruption, rebalance
# recommendations, and AWS Health events instead of losing them abruptly.

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = local.cluster_name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "EC2InterruptionPolicy"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        Sid       = "DenyHTTP"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.karpenter_interruption.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_cloudwatch_event_rule" "karpenter_scheduled_change" {
  name = "${var.name_prefix}-karpenter-health-event"
  event_pattern = jsonencode({
    source        = ["aws.health"]
    "detail-type" = ["AWS Health Event"]
  })
}

resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  name = "${var.name_prefix}-karpenter-spot-interruption"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_rule" "karpenter_rebalance" {
  name = "${var.name_prefix}-karpenter-rebalance"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_rule" "karpenter_instance_state_change" {
  name = "${var.name_prefix}-karpenter-instance-state-change"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_rule" "karpenter_capacity_reservation" {
  name = "${var.name_prefix}-karpenter-capacity-reservation"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Capacity Reservation Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_interruption_queue" {
  for_each = {
    scheduled_change      = aws_cloudwatch_event_rule.karpenter_scheduled_change.name
    spot_interruption     = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
    rebalance             = aws_cloudwatch_event_rule.karpenter_rebalance.name
    instance_state_change = aws_cloudwatch_event_rule.karpenter_instance_state_change.name
    capacity_reservation  = aws_cloudwatch_event_rule.karpenter_capacity_reservation.name
  }
  rule = each.value
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

# ---- Karpenter: Helm release ----

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  namespace        = var.karpenter_namespace
  create_namespace = true

  set {
    name  = "settings.clusterName"
    value = aws_eks_cluster.main.name
  }

  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruption.name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }

  depends_on = [
    aws_eks_node_group.system,
    aws_eks_access_entry.karpenter_node,
    aws_iam_role_policy.karpenter_node_lifecycle,
    aws_iam_role_policy.karpenter_iam_integration,
    aws_iam_role_policy.karpenter_eks_integration,
    aws_iam_role_policy.karpenter_interruption,
    aws_iam_role_policy.karpenter_resource_discovery,
  ]
}

# ---- Karpenter: default NodePool / EC2NodeClass ----
# EC2NodeClass.spec.role (not a precreated instance profile) — Karpenter
# manages the instance profile itself using the IAMIntegrationPolicy grants
# above. Subnets are discovered via the karpenter.sh/discovery tag the
# network module applies to private subnets; the security group is the
# cluster's own control-plane security group, referenced directly by ID.
# amiSelectorTerms uses the al2023@latest alias — fine for a demo where
# nodes are short-lived and ephemeral; Karpenter's own docs call this out as
# not recommended for production (an AMI release drifts/replaces nodes).

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      role = aws_iam_role.karpenter_node.name
      amiSelectorTerms = [
        { alias = "al2023@latest" },
      ]
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.name_prefix } },
      ]
      securityGroupSelectorTerms = [
        { id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id },
      ]
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        spec = {
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot", "on-demand"] },
            { key = "karpenter.k8s.aws/instance-category", operator = "In", values = ["c", "m", "r"] },
            { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["2"] },
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          expireAfter = "720h"
        }
      }
      # Demo cost guardrail: cap how much Karpenter capacity can exist at
      # once so a runaway batch can't blow the showcase budget.
      limits = { cpu = "100" }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class]
}
