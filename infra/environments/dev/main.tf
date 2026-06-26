# Dev environment — composes the modules in dependency order.
# Build phase by phase: uncomment each module block only when the previous
# one applies cleanly (see CLAUDE.md > Build phases).

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    helm       = { source = "hashicorp/helm", version = "~> 2.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = "burstlab"
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}

# locals { name_prefix = "burstlab-${var.env}" }

# ---- Phase 2 ----
# module "network" {
#   source      = "../../modules/network"
#   name_prefix = local.name_prefix
#   aws_region  = var.aws_region
# }

# ---- Phase 3 ----
# module "cluster" {
#   source      = "../../modules/cluster"
#   name_prefix = local.name_prefix
#   vpc_id      = module.network.vpc_id
#   subnet_ids  = module.network.private_subnet_ids
# }

# ---- Phase 4 ----
# module "platform" {
#   source            = "../../modules/platform"
#   cluster_name      = module.cluster.cluster_name
#   oidc_provider_arn = module.cluster.oidc_provider_arn
# }

# ---- Phase 5 ----
# module "app_resources" {
#   source            = "../../modules/app-resources"
#   name_prefix       = local.name_prefix
#   oidc_provider_arn = module.cluster.oidc_provider_arn
# }
