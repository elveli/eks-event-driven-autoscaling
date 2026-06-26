# Wire this to the bucket/table created by infra/bootstrap, THEN run:
#   terraform init -migrate-state
terraform {
  backend "s3" {
    bucket         = "TODO-state-bucket-name"
    key            = "burstlab/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "burstlab-tf-locks"
    encrypt        = true
  }
}
