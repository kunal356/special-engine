terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Remote state - required for CI/CD, since GitHub Actions runners are
  # ephemeral and have no local state file between runs. Bucket and lock
  # table are created once by bootstrap/ (see that folder's README), then
  # referenced here by name.
  backend "s3" {
    bucket       = "ecommerce-etl-tfstate"
    key          = "ecommerce-etl/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
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
