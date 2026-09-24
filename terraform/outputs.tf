output "raw_bucket_name" {
  description = "S3 bucket where raw store order files are uploaded"
  value       = aws_s3_bucket.raw_data.id
}

output "processed_bucket_name" {
  description = "S3 bucket where cleaned Parquet output lands"
  value       = aws_s3_bucket.processed_data.id
}

output "glue_assets_bucket_name" {
  description = "S3 bucket holding the Glue job script and temp files"
  value       = aws_s3_bucket.glue_assets.id
}

output "athena_results_bucket_name" {
  description = "S3 bucket where Athena writes query results"
  value       = aws_s3_bucket.athena_results.id
}

output "glue_database_name" {
  description = "Glue Catalog database name"
  value       = aws_glue_catalog_database.ecommerce.name
}

output "athena_workgroup_name" {
  description = "Athena workgroup to select when running queries"
  value       = aws_athena_workgroup.ecommerce.name
}

output "state_machine_arn" {
  description = "ARN of the Step Functions pipeline, useful for manual executions or CI/CD triggers"
  value       = aws_sfn_state_machine.ecommerce_pipeline.arn
}

output "pipeline_alerts_topic_arn" {
  description = "SNS topic ARN for pipeline failure alerts - subscribe additional endpoints here if needed"
  value       = aws_sns_topic.pipeline_alerts.arn
}
