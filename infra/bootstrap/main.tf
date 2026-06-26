# Phase 1 — Remote state backend.
# Uses LOCAL state itself (chicken-and-egg is expected here).
# Apply this by hand FIRST, then point environments/dev/backend.tf at it.

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = "burstlab"
      ManagedBy = "terraform"
    }
  }
}

# TODO: aws_s3_bucket for state (versioning enabled, public access blocked,
#       SSE enabled). Name from var.state_bucket_name.
# TODO: aws_dynamodb_table for state locking (LockID hash key, PAY_PER_REQUEST).
