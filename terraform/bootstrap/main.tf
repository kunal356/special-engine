/*
Bootstrap: creates the S3 bucket + DynamoDB lock table that the MAIN
Terraform config (one directory up) uses as its remote state backend.

This has to be a separate root module with its own LOCAL state, run once,
manually, before CI/CD ever touches the main config. Chicken-and-egg
problem otherwise: the main config's `backend "s3"` block needs this
bucket to already exist before `terraform init` can even run there, so
it can't be the thing that creates its own backend.

Usage (run once, by hand, from this directory):
    terraform init
    terraform apply

Then note the bucket/table names (defaults match main.tf's backend block
already) and never touch this again unless you're intentionally changing
where state lives.
*/

terraform {

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # Deliberately no backend block - this bootstrap config's own state
  # stays local. It's tiny, changes essentially never, and bootstrapping
  # its own remote backend would reintroduce the same chicken-and-egg
  # problem it exists to solve.
}

variable "aws_region" {
  type    = string
  default = "eu-west-2"
}

variable "project_name" {
  type    = string
  default = "ecommerce-etl"
}

provider "aws" {
  region = var.aws_region
}

resource "aws_s3_bucket" "tf_state" {
  bucket = "${var.project_name}-tfstate"

  # Protects against `terraform destroy` (bootstrap or otherwise)
  # accidentally deleting the bucket holding every other bucket's state.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_locks" {
  name         = "${var.project_name}-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket_name" {
  value = aws_s3_bucket.tf_state.id
}

output "lock_table_name" {
  value = aws_dynamodb_table.tf_locks.name
}
