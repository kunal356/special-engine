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
# Data quality check: Great Expectations validation of the processed data,
# run as a Python Shell job rather than a Spark ETL job. This step doesn't
# need distributed compute, and Python Shell starts in seconds rather than
# the minute-plus cold start of a Spark job, which matters for a validation
# gate that runs on every single pipeline execution.
# -----------------------------------------------------------------------------
resource "aws_glue_job" "data_quality_check" {
  name         = "${var.project_name}-data-quality-check"
  role_arn     = aws_iam_role.glue_etl_role.arn
  glue_version = "3.0" # Python Shell jobs are pinned to Glue 1.0/2.0/3.0
  max_capacity = 1      # smallest Python Shell size (1 DPU); this is a lightweight validation step

  command {
    name            = "pythonshell"
    script_location = "s3://${aws_s3_bucket.glue_assets.id}/${var.glue_dq_script_key}"
    python_version  = "3.9"
  }

  default_arguments = {
    "--additional-python-modules" = "great_expectations==1.3.*,pandas,pyarrow"
    "--target_path"               = "s3://${aws_s3_bucket.processed_data.id}/orders/"
    "--report_bucket"             = aws_s3_bucket.processed_data.id
    "--report_prefix"             = var.quality_report_prefix
    "--sns_topic_arn"             = aws_sns_topic.pipeline_alerts.arn
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
