terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Uncomment and configure once you're ready to move state off your laptop.
  # A local state file is fine for solo learning, but a real team setup
  # would use an S3 backend + DynamoDB lock table here.
  #
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "ecommerce-etl/terraform.tfstate"
  #   region         = "eu-west-2"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Used to build globally-unique S3 bucket names
data "aws_caller_identity" "current" {}
