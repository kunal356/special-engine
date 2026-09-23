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

# Catalog database - Metadata Table
resource "aws_glue_catalog_database" "ecommerce" {
  name = "ecommerce_raw_db"
}

# Crawler IAM role - Role the crawler assumes to read S3 bucket and write to Glue Catalog
resource "aws_iam_role" "glue_crawler_role" {
  name = "glue-crawler-ecommerce-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
            Service = "glue.amazonaws.com"
            }
        }]
  })
}

# AWS managed policy covering standard Glue service permissions
resource "aws_iam_role_policy_attachment" "glue_service" {
    role = aws_iam_role.glue_crawler_role.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
  
}

# Custom policy scoped to just bucket
resource "aws_iam_role_policy" "glue_s3_access" {
    name = "glue-s3-raw-access"
    role = aws_iam_role.glue_crawler_role.id

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Action = ["s3:GetObject", "s3:ListBucket"]
            Resource = [
                aws_s3_bucket.raw_data.arn, 
                "${aws_s3_bucket.raw_data.arn}/*"
            ]
        }]
    })  
}

# The crawler - points at raw zone, infers schema per partition
resource "aws_glue_crawler" "raw_orders" {
  name = "ecommerce-raw-orders-crawler"
  role = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.ecommerce.name

  s3_target {
    path = "s3://${aws_s3_bucket.raw_data.id}/raw/"
  }

  configuration = jsonencode({
    Version = 1.0
    Grouping = {
        TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })
}

#############
# Athena needs somewhere to write query results - every query execution
# lands here as a CSV, even if you never look at it directly
resource "aws_s3_bucket" "athena_results" {
  bucket = "ecommerce-etl-athena-results-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project = "ecommerce-etl-pipeline"
    Layer   = "athena-results"
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Auto-expire old query result files
resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-old-query-results"
    status = "Enabled"

    expiration {
      days = 7
    }
  }
}

# Workgroup - lets you enforce settings
resource "aws_athena_workgroup" "ecommerce" {
  name = "ecommerce-etl-workgroup"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/output/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# A saved query, to immediately see the raw data
resource "aws_athena_named_query" "sample_raw_query" {
  name      = "preview-raw-orders"
  workgroup = aws_athena_workgroup.ecommerce.id
  database  = aws_glue_catalog_database.ecommerce.name
  query     = "SELECT * FROM ${aws_glue_catalog_database.ecommerce.name}.raw LIMIT 10;"
}