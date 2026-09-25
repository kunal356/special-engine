# -----------------------------------------------------------------------------
# Retry policies, scoped to actual transient errors rather than States.ALL.
# Permanent errors (AccessDenied, EntityNotFound, bad config) should fail
# fast and go straight to Catch, retrying them just delays the alert.
# AWS SDK-integration Glue errors surface prefixed as "Glue.<ExceptionName>".
# -----------------------------------------------------------------------------
locals {
  crawler_transient_retry = {
    ErrorEquals     = ["Glue.ThrottlingException", "Glue.InternalServiceException", "Glue.ConcurrentRunsExceededException"]
    IntervalSeconds = 5
    MaxAttempts     = 3
    BackoffRate     = 2.0
  }

  job_transient_retry = {
    ErrorEquals     = ["Glue.ConcurrentRunsExceededException", "Glue.InternalServiceException"]
    IntervalSeconds = 10
    MaxAttempts     = 3
    BackoffRate     = 2.0
  }

  # Broader on purpose: this only guards the failure-notification path
  # itself, not core pipeline logic, so erring toward "keep trying to
  # tell someone" is the right call here.
  sns_retry = {
    ErrorEquals     = ["States.ALL"]
    IntervalSeconds = 2
    MaxAttempts     = 2
    BackoffRate     = 2.0
  }
}

# -----------------------------------------------------------------------------
# State machine
#
# Failure handling summary:
#   - Retry: only transient AWS errors, with backoff (see locals above).
#   - Catch: every task routes failures to a small per-task Pass state that
#     records which step actually failed, then on to the shared
#     NotifyFailure state. (The Context Object's $$.State.Name inside
#     NotifyFailure would otherwise just say "NotifyFailure" itself, not
#     the task that triggered it, so the origin has to be captured before
#     the transition.)
#   - Crawler success/failure is read from Crawler.LastCrawl.Status
#     (SUCCEEDED / FAILED / CANCELLED), not Crawler.State, which only ever
#     reports READY / RUNNING / STOPPING and never reflects failure.
#   - Each polling loop is bounded by max_crawler_poll_attempts, so a
#     crawler stuck in RUNNING/STOPPING fails the pipeline instead of
#     polling forever. TimeoutSeconds on the state machine is a second,
#     coarser safety net covering the whole execution.
#   - NotifyFailure itself is wrapped in Retry/Catch, so a broken SNS
#     publish still reaches a terminal Fail state instead of leaving the
#     execution stuck.
#   - A dedicated Great Expectations data quality gate runs after the
#     transform job and before the processed crawler - the processed data
#     never becomes queryable in Athena if it fails critical checks.
# -----------------------------------------------------------------------------
resource "aws_sfn_state_machine" "ecommerce_pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = jsonencode({
    Comment        = "Raw crawl -> transform -> data quality check -> processed crawl, with retry/catch/timeout on every step"
    StartAt        = "StartRawCrawler"
    TimeoutSeconds = 3600

    States = {
      # ---- Raw crawler ----
      StartRawCrawler = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = { Name = aws_glue_crawler.raw_orders.name }
        Retry      = [local.crawler_transient_retry]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "HandleStartRawCrawlerFailure" }]
        Next       = "InitRawPoll"
      }
      InitRawPoll = {
        Type       = "Pass"
        Parameters = { attempts = 0 }
        ResultPath = "$.rawPoll"
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
        Retry      = [local.crawler_transient_retry]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "HandleCheckRawCrawlerFailure" }]
        Next       = "IncrementRawPoll"
      }
      IncrementRawPoll = {
        Type       = "Pass"
        Parameters = { "attempts.$" = "States.MathAdd($.rawPoll.attempts, 1)" }
        ResultPath = "$.rawPoll"
        Next       = "IsRawCrawlerReady"
      }
      IsRawCrawlerReady = {
        Type = "Choice"
        Choices = [{
          Variable     = "$.crawlerStatus.Crawler.State"
          StringEquals = "READY"
          Next         = "CheckRawCrawlResult"
        }]
        Default = "IsRawPollTimedOut"
      }
      IsRawPollTimedOut = {
        Type = "Choice"
        Choices = [{
          Variable                 = "$.rawPoll.attempts"
          NumericGreaterThanEquals = var.max_crawler_poll_attempts
          Next                     = "HandleRawCrawlerTimeout"
        }]
        Default = "WaitRawCrawler"
      }
      HandleRawCrawlerTimeout = {
        Type = "Pass"
        Parameters = {
          Error       = "CrawlerTimeout"
          Cause       = "Raw crawler did not reach READY state within the allotted polling window"
          FailedState = "StartRawCrawler / CheckRawCrawler (polling loop)"
        }
        ResultPath = "$.error"
        Next       = "NotifyFailure"
      }
      CheckRawCrawlResult = {
        Type = "Choice"
        Choices = [{
          Variable     = "$.crawlerStatus.Crawler.LastCrawl.Status"
          StringEquals = "SUCCEEDED"
          Next         = "RunTransformJob"
        }]
        Default = "HandleRawCrawlFailed"
      }
      HandleRawCrawlFailed = {
        Type = "Pass"
        Parameters = {
          Error       = "CrawlerRunFailed"
          "Cause.$"   = "States.Format('Raw crawler run did not succeed (LastCrawl.Status: {})', $.crawlerStatus.Crawler.LastCrawl.Status)"
          FailedState = "CheckRawCrawler"
        }
        ResultPath = "$.error"
        Next       = "NotifyFailure"
      }
      HandleStartRawCrawlerFailure = {
        Type = "Pass"
        Parameters = {
          "Error.$"   = "$.error.Error"
          "Cause.$"   = "$.error.Cause"
          FailedState = "StartRawCrawler"
        }
        ResultPath = "$.error"
        Next       = "NotifyFailure"
      }
      HandleCheckRawCrawlerFailure = {
        Type = "Pass"
        Parameters = {
          "Error.$"   = "$.error.Error"
          "Cause.$"   = "$.error.Cause"
          FailedState = "CheckRawCrawler"
        }
        ResultPath = "$.error"
        Next       = "NotifyFailure"
      }

      # ---- Transform job ----
      RunTransformJob = {
        Type       = "Task"
        Resource   = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = { JobName = aws_glue_job.transform_orders.name }
        Retry      = [local.job_transient_retry]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "HandleRunTransformJobFailure" }]
        Next       = "RunDataQualityCheck"
      }
      HandleRunTransformJobFailure = {
        Type = "Pass"
        Parameters = {
          "Error.$"   = "$.error.Error"
          "Cause.$"   = "$.error.Cause"
          FailedState = "RunTransformJob"
        }
        ResultPath = "$.error"
        Next       = "NotifyFailure"
      }

      # ---- Data quality gate (Great Expectations) ----
      # Runs after transform, before the processed data is cataloged and
      # exposed to Athena. A critical-severity failure here (see
      # scripts/data_quality_check.py) fails this Glue job run, which this
      # Catch routes to the shared failure path - the processed crawler
      # never runs against data that failed critical checks.
      RunDataQualityCheck = {
        Type       = "Task"
        Resource   = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = { JobName = aws_glue_job.data_quality_check.name }
        Retry      = [local.job_transient_retry]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "HandleDataQualityCheckFailure" }]
        Next       = "StartProcessedCrawler"
      }
      HandleDataQualityCheckFailure = {
        Type = "Pass"
        Parameters = {
          "Error.$"   = "$.error.Error"
          "Cause.$"   = "$.error.Cause"
          FailedState = "RunDataQualityCheck"
        }
        ResultPath = "$.error"
        Next       = "NotifyFailure"
      }

      # ---- Processed crawler (mirrors the raw crawler flow above) ----
      StartProcessedCrawler = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = { Name = aws_glue_crawler.processed_orders.name }
        Retry      = [local.crawler_transient_retry]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "HandleStartProcessedCrawlerFailure" }]
        Next       = "InitProcessedPoll"
      }
      InitProcessedPoll = {
        Type       = "Pass"
        Parameters = { attempts = 0 }
        ResultPath = "$.processedPoll"
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
        Retry      = [local.crawler_transient_retry]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "HandleCheckProcessedCrawlerFailure" }]
        Next       = "IncrementProcessedPoll"
      }
      IncrementProcessedPoll = {
        Type       = "Pass"
        Parameters = { "attempts.$" = "States.MathAdd($.processedPoll.attempts, 1)" }
        ResultPath = "$.processedPoll"
        Next       = "IsProcessedCrawlerReady"
      }
      IsProcessedCrawlerReady = {
        Type = "Choice"
        Choices = [{
          Variable     = "$.crawlerStatus.Crawler.State"
          StringEquals = "READY"
          Next         = "CheckProcessedCrawlResult"
        }]
        Default = "IsProcessedPollTimedOut"
      }
      IsProcessedPollTimedOut = {
        Type = "Choice"
        Choices = [{
          Variable                 = "$.processedPoll.attempts"
          NumericGreaterThanEquals = var.max_crawler_poll_attempts
          Next                     = "HandleProcessedCrawlerTimeout"
        }]
        Default = "WaitProcessedCrawler"
      }
      HandleProcessedCrawlerTimeout = {
        Type = "Pass"
        Parameters = {
          Error       = "CrawlerTimeout"
          Cause       = "Processed crawler did not reach READY state within the allotted polling window"
          FailedState = "StartProcessedCrawler / CheckProcessedCrawler (polling loop)"
        }
        ResultPath = "$.error"
        Next       = "NotifyFailure"
      }
      CheckProcessedCrawlResult = {
        Type = "Choice"
        Choices = [{
          Variable     = "$.crawlerStatus.Crawler.LastCrawl.Status"
          StringEquals = "SUCCEEDED"
          Next         = "Success"
        }]
        Default = "HandleProcessedCrawlFailed"
      }
      HandleProcessedCrawlFailed = {
        Type = "Pass"
        Parameters = {
          Error       = "CrawlerRunFailed"
          "Cause.$"   = "States.Format('Processed crawler run did not succeed (LastCrawl.Status: {})', $.crawlerStatus.Crawler.LastCrawl.Status)"
          FailedState = "CheckProcessedCrawler"
        }
        ResultPath = "$.error"
        Next       = "NotifyFailure"
      }
      HandleStartProcessedCrawlerFailure = {
        Type = "Pass"
        Parameters = {
          "Error.$"   = "$.error.Error"
          "Cause.$"   = "$.error.Cause"
          FailedState = "StartProcessedCrawler"
        }
        ResultPath = "$.error"
        Next       = "NotifyFailure"
      }
      HandleCheckProcessedCrawlerFailure = {
        Type = "Pass"
        Parameters = {
          "Error.$"   = "$.error.Error"
          "Cause.$"   = "$.error.Cause"
          FailedState = "CheckProcessedCrawler"
        }
        ResultPath = "$.error"
        Next       = "NotifyFailure"
      }

      # ---- Shared failure notification ----
      # Every failure path above guarantees $.error = {Error, Cause, FailedState}
      # is populated before arriving here.
      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.pipeline_alerts.arn
          Subject     = "${var.project_name} pipeline FAILED"
          "Message.$" = "States.Format('Pipeline failed.\nFailed step: {}\nError: {}\nCause: {}\nExecution: {}\nExecution ID: {}', $.error.FailedState, $.error.Error, $.error.Cause, $$.Execution.Name, $$.Execution.Id)"
        }
        Retry = [local.sns_retry]
        Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.snsPublishError", Next = "Fail" }]
        Next  = "Fail"
      }
      Fail = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "See the SNS notification (if delivered) or Step Functions execution history for details"
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
  role_arn = aws_iam_role.eventbridge_invoke_role.arn
}
