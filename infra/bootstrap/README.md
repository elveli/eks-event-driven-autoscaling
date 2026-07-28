# Phase 1 — Bootstrap

Creates the S3 bucket + DynamoDB lock table that hold remote state for every
other layer. Run this once, by hand, with local state.

    terraform init
    terraform apply -var="state_bucket_name=YOUR-UNIQUE-NAME"

Then copy `../environments/dev/backend.hcl.example` to `backend.hcl` (gitignored),
fill in `state_bucket_name` from the output above, and run
`terraform init -backend-config=backend.hcl -migrate-state` there.

For CI's own `terraform init` (`.github/workflows/infra.yml`), set the same
bucket name as a repo variable once:

    gh variable set TF_STATE_BUCKET --body "$(terraform output -raw state_bucket_name)"

Claude: scaffold the S3 + DynamoDB resources in main.tf per the TODOs.
