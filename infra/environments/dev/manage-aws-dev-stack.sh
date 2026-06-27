#!/usr/bin/env bash
# Plan/apply/destroy the dev environment as a single unit.
#
# Scope: everything composed in this directory's main.tf (network, and
# cluster/platform/app-resources as those phases get uncommented). This
# script intentionally never touches infra/bootstrap — the state bucket and
# DynamoDB lock table stay up 24/7; only resources here are meant to be
# torn down between sessions (see CLAUDE.md > Cost discipline).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
  echo "Usage: $0 {plan|apply|destroy}" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage

case "$1" in
  plan)
    terraform init -input=false
    terraform plan -input=false
    ;;
  apply)
    terraform init -input=false
    terraform apply
    ;;
  destroy)
    echo "This will DESTROY all resources in infra/environments/dev."
    echo "infra/bootstrap (state bucket + lock table) is NOT affected."
    read -rp "Type 'destroy' to confirm: " confirm
    [[ "$confirm" == "destroy" ]] || { echo "Aborted."; exit 1; }
    terraform destroy
    ;;
  *)
    usage
    ;;
esac
