# Phase 2 — Network
# TODO:
#  - VPC (var.vpc_cidr)
#  - public + private subnets across 2 AZs
#  - ONE NAT gateway (cost decision — do NOT do one-per-AZ in dev)
#  - Internet gateway + route tables
#  - S3 GATEWAY endpoint (free) so image layers / S3 traffic skip the NAT
#  - ECR (api + dkr) and STS INTERFACE endpoints so ECR pulls skip the NAT
#  - Tag subnets for EKS + Karpenter discovery:
#      kubernetes.io/role/elb = 1            (public)
#      kubernetes.io/role/internal-elb = 1   (private)
#      karpenter.sh/discovery = var.name_prefix
