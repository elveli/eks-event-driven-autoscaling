# Phase 1 — Bootstrap

Creates the S3 bucket + DynamoDB lock table that hold remote state for every
other layer. Run this once, by hand, with local state.

    terraform init
    terraform apply -var="state_bucket_name=YOUR-UNIQUE-NAME"

Then copy the outputs into `../environments/dev/backend.tf` and run
`terraform init -migrate-state` there.

Claude: scaffold the S3 + DynamoDB resources in main.tf per the TODOs.
