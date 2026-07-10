# Dev environment — composes the modules in dependency order.
# Build phase by phase: uncomment each module block only when the previous
# one applies cleanly (see CLAUDE.md > Build phases).

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    helm       = { source = "hashicorp/helm", version = "~> 2.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
    kubectl    = { source = "gavinbunney/kubectl", version = "~> 1.14" }
    archive    = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = "eda"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}

locals { name_prefix = "eda-${var.env}" }

# ---- Phase 2 ----
module "network" {
  source      = "../../modules/network"
  name_prefix = local.name_prefix
  aws_region  = var.aws_region
}

# ---- Phase 3 ----
module "cluster" {
  source      = "../../modules/cluster"
  name_prefix = local.name_prefix
  subnet_ids  = module.network.private_subnet_ids
}

# Auth for the kubernetes/helm/kubectl providers below. These read from
# module.cluster, which doesn't exist until the cluster is created in this
# same apply — see the chicken-and-egg note in modules/cluster/main.tf.
data "aws_eks_cluster_auth" "this" {
  name = module.cluster.cluster_name
}

provider "kubernetes" {
  host                   = module.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  host                   = module.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
}

# ---- Phase 4 ----
module "platform" {
  source            = "../../modules/platform"
  cluster_name      = module.cluster.cluster_name
  oidc_provider_arn = module.cluster.oidc_provider_arn
  vpc_id            = module.network.vpc_id
}

# ---- Phase 5 ----
module "app_resources" {
  source            = "../../modules/app-resources"
  name_prefix       = local.name_prefix
  oidc_provider_arn = module.cluster.oidc_provider_arn
}

# ---- Phase 6: app identity/config contract ----
# The Kubernetes-side half of the app wiring. These three objects carry
# AWS-specific values (a role ARN, the queue URL, the Lambda origin) that must
# NOT be committed to gitops/ (CLAUDE.md rule 3: no account IDs in code), so
# Terraform owns them and the Argo CD-synced manifests reference them by name:
#   - namespace eda             — Argo CD syncs the app into it
#   - ServiceAccount eda-worker — IRSA annotation -> worker role
#   - ConfigMap eda-app-config  — QUEUE_URL/BUCKET/AWS_REGION for the worker,
#     LAMBDA_ORIGIN for the dashboard's nginx /api proxy. The KEDA
#     ScaledObject also gets the queue URL from here, indirectly: it uses
#     queueURLFromEnv, which KEDA resolves from the worker container's env.
# Everything with no AWS identifier in it (eda-web SA, RBAC, Deployments,
# Service, Ingress, ScaledObject, HPA) lives in gitops/manifests instead.

resource "kubernetes_namespace" "eda" {
  metadata {
    name = "eda"
  }
}

resource "kubernetes_service_account" "worker" {
  metadata {
    name      = "eda-worker"
    namespace = kubernetes_namespace.eda.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = module.app_resources.worker_role_arn
    }
  }
}

resource "kubernetes_config_map" "app_config" {
  metadata {
    name      = "eda-app-config"
    namespace = kubernetes_namespace.eda.metadata[0].name
  }

  data = {
    QUEUE_URL  = module.app_resources.jobs_queue_url
    BUCKET     = module.app_resources.bucket_name
    AWS_REGION = var.aws_region
    # Host only, no scheme or trailing slash — it lands in nginx's
    # proxy_pass and Host header in the web pod.
    LAMBDA_ORIGIN = trimsuffix(trimprefix(module.app_resources.lambda_function_url, "https://"), "/")
  }
}
