# -----------------------------------------------------------------------------
# Glue Crawler role - read-only access to raw + processed buckets
# -----------------------------------------------------------------------------
resource "aws_iam_role" "glue_crawler_role" {
  name = "${var.project_name}-glue-crawler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_crawler_service" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_crawler_raw_s3_access" {
  name = "glue-crawler-raw-s3-access"
  role = aws_iam_role.glue_crawler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.raw_data.arn, "${aws_s3_bucket.raw_data.arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy" "glue_crawler_processed_s3_access" {
  name = "glue-crawler-processed-s3-access"
  role = aws_iam_role.glue_crawler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.processed_data.arn, "${aws_s3_bucket.processed_data.arn}/*"]
    }]
  })
}

# -----------------------------------------------------------------------------
# Glue ETL job role - read raw, read/write processed, read/write glue assets
# -----------------------------------------------------------------------------
resource "aws_iam_role" "glue_etl_role" {
  name = "${var.project_name}-glue-etl-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_etl_service" {
  role       = aws_iam_role.glue_etl_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_etl_s3_access" {
  name = "glue-etl-s3-access"
  role = aws_iam_role.glue_etl_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.raw_data.arn, "${aws_s3_bucket.raw_data.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [aws_s3_bucket.processed_data.arn, "${aws_s3_bucket.processed_data.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.glue_assets.arn, "${aws_s3_bucket.glue_assets.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.pipeline_alerts.arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Step Functions role - start/poll Glue crawlers and jobs
# -----------------------------------------------------------------------------
resource "aws_iam_role" "step_functions_role" {
  name = "${var.project_name}-stepfunctions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "step_functions_glue_access" {
  name = "stepfunctions-glue-access"
  role = aws_iam_role.step_functions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:StartCrawler",
          "glue:GetCrawler",
          "glue:StartJobRun",
          "glue:GetJobRun",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.pipeline_alerts.arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# EventBridge role - separate from step_functions_role on purpose. That
# role's trust policy only allows states.amazonaws.com to assume it, so
# EventBridge (events.amazonaws.com) cannot use it to start executions,
# a fairly easy mistake to copy-paste into. This role exists solely so the
# scheduled trigger can call states:StartExecution.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "eventbridge_invoke_role" {
  name = "${var.project_name}-eventbridge-invoke-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_start_execution" {
  name = "eventbridge-start-execution"
  role = aws_iam_role.eventbridge_invoke_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = aws_sfn_state_machine.ecommerce_pipeline.arn
    }]
  })
}
