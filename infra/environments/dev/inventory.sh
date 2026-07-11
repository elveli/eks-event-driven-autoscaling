#!/usr/bin/env bash
# Leak check for `make inventory`: every Project=eda resource, cross-verified
# against live AWS.
#
# Why this exists and isn't just the raw tagging-API call: the Resource
# Groups Tagging API (what lists "everything tagged Project=eda") lags
# actual deletion — observed firsthand where VPC endpoint ARNs kept showing
# up for hours after `aws ec2 describe-vpc-endpoints` on those same IDs
# already returned NotFound. A stale index entry is indistinguishable from a
# real leak unless something re-checks it, so every ARN here gets a live
# existence call via its own service API before being reported.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

REGION="$(terraform output -raw aws_region 2>/dev/null || true)"
REGION="${REGION:-us-east-1}"

# Returns 0 (exists), 1 (confirmed gone), or 2 (don't know how to check this
# resource type — reported unverified rather than silently hidden).
exists() {
  local arn="$1" svc rest rid
  svc="$(cut -d: -f3 <<<"$arn")"
  rest="$(cut -d: -f6- <<<"$arn")"
  case "$svc" in
    ec2)
      # `describe-tags` looked like a nice one-liner covering every EC2
      # sub-resource, but it turned out to source from the SAME lagging tag
      # index as the Resource Groups Tagging API — it kept reporting a
      # deleted vpc-endpoint's tags hours after `describe-vpc-endpoints` on
      # that same ID had already gone NotFound. Only a direct per-type
      # describe call against the resource itself is authoritative.
      local rtype id state
      rtype="$(cut -d/ -f1 <<<"$rest")"
      id="$(cut -d/ -f2 <<<"$rest")"
      case "$rtype" in
        vpc)               aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$id" >/dev/null 2>&1 ;;
        subnet)            aws ec2 describe-subnets --region "$REGION" --subnet-ids "$id" >/dev/null 2>&1 ;;
        elastic-ip)        aws ec2 describe-addresses --region "$REGION" --allocation-ids "$id" >/dev/null 2>&1 ;;
        security-group)    aws ec2 describe-security-groups --region "$REGION" --group-ids "$id" >/dev/null 2>&1 ;;
        internet-gateway)  aws ec2 describe-internet-gateways --region "$REGION" --internet-gateway-ids "$id" >/dev/null 2>&1 ;;
        route-table)       aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$id" >/dev/null 2>&1 ;;
        # These two can linger in a terminal "deleted" state for a while
        # instead of erroring outright, so check state, not just call success.
        natgateway)
          state="$(aws ec2 describe-nat-gateways --region "$REGION" --nat-gateway-ids "$id" \
                     --query 'NatGateways[0].State' --output text 2>/dev/null)" || return 1
          [ "$state" != "deleted" ]
          ;;
        vpc-endpoint)
          state="$(aws ec2 describe-vpc-endpoints --region "$REGION" --vpc-endpoint-ids "$id" \
                     --query 'VpcEndpoints[0].State' --output text 2>/dev/null)" || return 1
          [ "$state" != "deleted" ]
          ;;
        *) return 2 ;;
      esac
      ;;
    dynamodb)
      aws dynamodb describe-table --region "$REGION" \
        --table-name "${rest##*/}" >/dev/null 2>&1
      ;;
    s3)
      aws s3api head-bucket --bucket "$(cut -d: -f6 <<<"$arn")" >/dev/null 2>&1
      ;;
    sqs)
      aws sqs get-queue-url --region "$REGION" \
        --queue-name "${rest##*/}" >/dev/null 2>&1
      ;;
    ecr)
      aws ecr describe-repositories --region "$REGION" \
        --repository-names "${rest#repository/}" >/dev/null 2>&1
      ;;
    lambda)
      aws lambda get-function --region "$REGION" \
        --function-name "${rest##*:}" >/dev/null 2>&1
      ;;
    eks)
      # cluster/X, nodegroup/X/Y/Z, and access-entry/X/... all carry the
      # cluster name as the segment right after the resource-type keyword —
      # nodegroups and access entries live only as long as their cluster
      # does in this project, so "cluster exists" is an accurate proxy.
      aws eks describe-cluster --region "$REGION" \
        --name "$(cut -d/ -f2 <<<"$rest")" >/dev/null 2>&1
      ;;
    iam)
      case "$rest" in
        oidc-provider/*) aws iam get-open-id-connect-provider \
            --open-id-connect-provider-arn "$arn" >/dev/null 2>&1 ;;
        policy/*)        aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1 ;;
        role/*)          aws iam get-role --role-name "${rest#role/}" >/dev/null 2>&1 ;;
        *) return 2 ;;
      esac
      ;;
    events)
      aws events describe-rule --region "$REGION" \
        --name "${rest#rule/}" >/dev/null 2>&1
      ;;
    *)
      return 2
      ;;
  esac
}

echo "── Terraform-managed (Project=eda tag), cross-verified live ──"
arns="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters Key=Project,Values=eda \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)"

if [ -z "$arns" ]; then
  echo "  none"
else
  tr '\t' '\n' <<<"$arns" | while read -r arn; do
    [ -z "$arn" ] && continue
    if exists "$arn"; then rc=0; else rc=$?; fi
    case "$rc" in
      0) echo "  $arn" ;;
      2) echo "  $arn  (unverified resource type — reported as-is)" ;;
      *) echo "  $arn  [STALE — already deleted, tagging index hasn't caught up]" ;;
    esac
  done
fi
