resource "aws_athena_workgroup" "ecommerce" {
  name = "${var.project_name}-workgroup"

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

resource "aws_athena_named_query" "sample_raw_query" {
  name      = "preview-raw-orders"
  workgroup = aws_athena_workgroup.ecommerce.id
  database  = aws_glue_catalog_database.ecommerce.name
  query     = "SELECT * FROM ${aws_glue_catalog_database.ecommerce.name}.raw LIMIT 10;"
}

resource "aws_athena_named_query" "sample_processed_query" {
  name      = "preview-processed-orders"
  workgroup = aws_athena_workgroup.ecommerce.id
  database  = aws_glue_catalog_database.ecommerce.name
  query     = "SELECT * FROM ${aws_glue_catalog_database.ecommerce.name}.orders LIMIT 10;"
}
