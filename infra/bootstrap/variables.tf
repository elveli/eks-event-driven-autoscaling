variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name for Terraform state."
}

variable "lock_table_name" {
  type    = string
  default = "eda-tf-locks"
}
