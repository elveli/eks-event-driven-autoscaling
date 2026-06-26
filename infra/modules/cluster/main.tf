# Phase 3 — Cluster
# TODO:
#  - EKS control plane, Kubernetes version PINNED (keep it current; extended
#    support = 6x control-plane cost). Expose as var.k8s_version.
#  - IAM OIDC provider for the cluster (foundation for IRSA everywhere).
#  - A small managed node group (2x t3.medium) ONLY to host system pods,
#    Karpenter, KEDA, Argo CD. Real workers run on Karpenter capacity.
#  - Karpenter: controller IAM role (IRSA), node IAM role + instance profile,
#    Helm release OR EKS add-on, and a default NodePool/EC2NodeClass that
#    prefers SPOT (cost) and uses the karpenter.sh/discovery subnet tag.
