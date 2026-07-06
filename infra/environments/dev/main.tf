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
  vpc_id      = module.network.vpc_id
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
