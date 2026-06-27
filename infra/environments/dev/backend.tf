# Wire this to the bucket/table created by infra/bootstrap, THEN run:
#   terraform init -migrate-state
terraform {
  backend "s3" {
    bucket         = "eks-event-driven-autoscaling-tfstate-558543825081"
    key            = "eda/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "eda-tf-locks"
    encrypt        = true
  }
}
