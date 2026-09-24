# Glue crawlers have no native Step Functions ".sync" integration, so we
# start the crawler, then poll GetCrawler in a Wait -> Check -> Choice loop
# until its state is READY. Glue Jobs *do* support ".sync" natively.
#
# Failure handling:
#   - Retry: transient AWS errors (throttling, brief API blips) are retried
#     with exponential backoff before being treated as a real failure.
#   - Catch: any task that still fails after retries are exhausted routes
#     to NotifyFailure, which publishes the error to SNS, then Fail, so a
#     broken run is visible immediately instead of silently vanishing.
locals {
  transient_retry = {
    ErrorEquals     = ["States.ALL"]
    IntervalSeconds = 5
    MaxAttempts     = 3
    BackoffRate     = 2.0
  }
}

resource "aws_sfn_state_machine" "ecommerce_pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = jsonencode({
    Comment = "Raw crawl -> transform -> processed crawl, with retry/catch on every step"
    StartAt = "StartRawCrawler"
    States = {
      StartRawCrawler = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = { Name = aws_glue_crawler.raw_orders.name }
        Retry      = [local.transient_retry]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "NotifyFailure" }]
        Next       = "WaitRawCrawler"
      }
      WaitRawCrawler = {
        Type    = "Wait"
        Seconds = 30
        Next    = "CheckRawCrawler"
      }
      CheckRawCrawler = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:glue:getCrawler"
        Parameters = { Name = aws_glue_crawler.raw_orders.name }
        ResultPath = "$.crawlerStatus"
        Retry      = [local.transient_retry]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "NotifyFailure" }]
        Next       = "IsRawCrawlerDone"
      }
      IsRawCrawlerDone = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.crawlerStatus.Crawler.State"
            StringEquals = "READY"
            Next         = "RunTransformJob"
          },
          {
            # A crawler in a FAILED state won't ever become READY - without
            # this branch the Wait/Check loop would poll forever.
            Variable     = "$.crawlerStatus.Crawler.State"
            StringEquals = "FAILED"
            Next         = "NotifyFailure"
          }
        ]
        Default = "WaitRawCrawler"
      }
      RunTransformJob = {
        Type       = "Task"
        Resource   = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = { JobName = aws_glue_job.transform_orders.name }
        Retry      = [local.transient_retry]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "NotifyFailure" }]
        Next       = "StartProcessedCrawler"
      }
      StartProcessedCrawler = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = { Name = aws_glue_crawler.processed_orders.name }
        Retry      = [local.transient_retry]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "NotifyFailure" }]
        Next       = "WaitProcessedCrawler"
      }
      WaitProcessedCrawler = {
        Type    = "Wait"
        Seconds = 30
        Next    = "CheckProcessedCrawler"
      }
      CheckProcessedCrawler = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:glue:getCrawler"
        Parameters = { Name = aws_glue_crawler.processed_orders.name }
        ResultPath = "$.crawlerStatus"
        Retry      = [local.transient_retry]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "NotifyFailure" }]
        Next       = "IsProcessedCrawlerDone"
      }
      IsProcessedCrawlerDone = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.crawlerStatus.Crawler.State"
            StringEquals = "READY"
            Next         = "Success"
          },
          {
            Variable     = "$.crawlerStatus.Crawler.State"
            StringEquals = "FAILED"
            Next         = "NotifyFailure"
          }
        ]
        Default = "WaitProcessedCrawler"
      }
      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.pipeline_alerts.arn
          Subject     = "ecommerce-etl-pipeline FAILED"
          "Message.$" = "States.Format('Pipeline failed at state: {}\nError: {}', $$.State.Name, States.JsonToString($.error))"
        }
        Next = "Fail"
      }
      Fail = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "See the SNS notification / Step Functions execution history for details"
      }
      Success = {
        Type = "Succeed"
      }
    }
  })
}

resource "aws_cloudwatch_event_rule" "daily_pipeline_trigger" {
  name                = "${var.project_name}-daily-trigger"
  schedule_expression = var.pipeline_schedule_expression
}

resource "aws_cloudwatch_event_target" "pipeline_target" {
  rule     = aws_cloudwatch_event_rule.daily_pipeline_trigger.name
  arn      = aws_sfn_state_machine.ecommerce_pipeline.arn
  role_arn = aws_iam_role.step_functions_role.arn
}
