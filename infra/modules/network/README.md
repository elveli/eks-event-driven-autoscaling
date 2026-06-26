# Phase 2 — Network module

VPC and everything that lets private worker nodes reach the world cheaply.

**Inputs:** `name_prefix`, `aws_region`, `vpc_cidr` (default 10.0.0.0/16).
**Outputs:** `vpc_id`, `public_subnet_ids`, `private_subnet_ids`.

Key cost decision (from CLAUDE.md): exactly ONE NAT gateway, plus S3 gateway
endpoint and ECR/STS interface endpoints so container pulls don't pay NAT
data-processing. Don't tag for one-NAT-per-AZ in dev.
