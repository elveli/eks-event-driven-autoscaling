# Network module — inputs

variable "name_prefix" {
  type        = string
  description = "Short resource prefix, e.g. eda-dev."
}

variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC."
  default     = "10.137.0.0/16"
}
