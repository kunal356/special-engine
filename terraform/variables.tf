variable "aws_region" {
  description = "AWS region to deploy the pipeline into"
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Short project name, used as a prefix/tag across resources"
  type        = string
  default     = "ecommerce-etl"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "glue_job_worker_type" {
  description = "Worker type for the Glue transform job"
  type        = string
  default     = "G.1X"
}

variable "glue_job_number_of_workers" {
  description = "Number of workers for the Glue transform job"
  type        = number
  default     = 2
}

variable "glue_script_key" {
  description = "S3 key (within the glue_assets bucket) where the transform script lives"
  type        = string
  default     = "scripts/transform_orders.py"
}

variable "athena_results_retention_days" {
  description = "Days to retain Athena query result files before auto-expiring them"
  type        = number
  default     = 7
}

variable "pipeline_schedule_expression" {
  description = "EventBridge cron/rate expression for the daily pipeline run"
  type        = string
  default     = "cron(0 2 * * ? *)"
}

variable "alert_email" {
  description = "Email address to notify when the pipeline fails. Leave empty to skip creating a subscription (you can add one manually in SNS later)."
  type        = string
  default     = ""
}
