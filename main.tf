terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "eu-west-2"
}

# Raw data zone - where regional stores drop their JSON files
resource "aws_s3_bucket" "raw_data" {
  bucket = "ecommerce-etl-raw-${data.aws_caller_identity.current.account_id}"
  tags = {
    Project = "ecommerce-etl-pipeline"
    Environment = "dev"
    Layer = "raw"
  }

}

# Using account ID so the bucket name is guaranted unique
data "aws_caller_identity" "current" {}

# Versioning
resource "aws_s3_bucket_versioning" "raw_data" {
    bucket = aws_s3_bucket.raw_data.id
    versioning_configuration {
      status = "Enabled"
    }
}

# Encryption at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "raw_data" {
    bucket = aws_s3_bucket.raw_data.id

    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "raw_data" {
  bucket = aws_s3_bucket.raw_data.id

  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}

output "raw_bucket_name" {
  value = aws_s3_bucket.raw_data.id
}