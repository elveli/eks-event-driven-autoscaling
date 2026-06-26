# Phase 4 — Platform add-ons (all via pinned Helm charts)
# TODO:
#  - AWS Load Balancer Controller (IRSA role w/ its IAM policy) -> enables ALB Ingress
#  - KEDA (keda-core chart). Its operator needs IRSA perms to read SQS/CloudWatch.
#  - Argo CD. Expose the server; you'll add an Application in gitops/apps later.
#  Pin every chart version. Use the helm + kubernetes providers configured from
#  the cluster module's outputs.
