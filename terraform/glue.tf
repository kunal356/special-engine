resource "aws_glue_catalog_database" "ecommerce" {
  # Kept as a literal, not derived from var.project_name, because this name
  # is already deployed - deriving it would force a destroy + recreate of
  # the database, taking every crawler-created table down with it.
  name = "ecommerce_raw_db"
}

# -----------------------------------------------------------------------------
# Crawler 1: raw zone -> infers schema from region=X/date=Y partitions
# -----------------------------------------------------------------------------
resource "aws_glue_crawler" "raw_orders" {
  name          = "${var.project_name}-raw-orders-crawler"
  role          = aws_iam_role.glue_crawler_role.arn
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

# -----------------------------------------------------------------------------
# Transform job: cleans + dedupes + writes Parquet, partitioned by region/year/month
# -----------------------------------------------------------------------------
resource "aws_glue_job" "transform_orders" {
  name              = "${var.project_name}-transform-orders"
  role_arn          = aws_iam_role.glue_etl_role.arn
  glue_version      = "4.0"
  worker_type       = var.glue_job_worker_type
  number_of_workers = var.glue_job_number_of_workers

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_assets.id}/${var.glue_script_key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-bookmark-option"               = "job-bookmark-enable"
    "--TempDir"                           = "s3://${aws_s3_bucket.glue_assets.id}/temp/"
    "--enable-metrics"                    = "true"
    "--enable-continuous-cloudwatch-log"  = "true"
    "--source_database"                   = aws_glue_catalog_database.ecommerce.name
    "--source_table"                      = "raw"
    "--target_path"                       = "s3://${aws_s3_bucket.processed_data.id}/orders/"
  }
}

# -----------------------------------------------------------------------------
# Crawler 2: processed zone -> makes cleaned Parquet queryable in Athena
# -----------------------------------------------------------------------------
resource "aws_glue_crawler" "processed_orders" {
  name          = "${var.project_name}-processed-orders-crawler"
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.ecommerce.name

  s3_target {
    path = "s3://${aws_s3_bucket.processed_data.id}/orders/"
  }

  configuration = jsonencode({
    Version = 1.0
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })
}
