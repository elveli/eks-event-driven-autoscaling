# Wire this to the bucket/table created by infra/bootstrap: copy
# backend.hcl.example to backend.hcl (gitignored), fill in the bucket name,
# THEN run:
#   terraform init -backend-config=backend.hcl -migrate-state
terraform {
  backend "s3" {
    # bucket intentionally omitted — Terraform backend blocks can't take
    # variables (they're needed before any provider/state exists), and the
    # bucket name is suffixed with the AWS account ID for S3's global
    # uniqueness requirement. Supplied at init time instead, so the account
    # ID never lands in a committed file: see backend.hcl.example.
    key            = "eda/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "eda-tf-locks"
    encrypt        = true
  }
}
