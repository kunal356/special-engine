# These watch the state machine from the outside, using AWS/States metrics,
# rather than relying on the pipeline's own NotifyFailure step. That matters
# because it still catches you if the failure-notification path itself is
# what breaks (bad IAM, SNS misconfigured, etc.) - the one category of
# problem the in-workflow SNS publish can never alert on by definition.

resource "aws_cloudwatch_metric_alarm" "pipeline_execution_failed" {
  alarm_name          = "${var.project_name}-execution-failed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Fires when the ecommerce ETL pipeline's Step Functions execution fails"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.ecommerce_pipeline.arn
  }

  alarm_actions = [aws_sns_topic.pipeline_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "pipeline_execution_timed_out" {
  alarm_name          = "${var.project_name}-execution-timed-out"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsTimedOut"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Fires when the ecommerce ETL pipeline's Step Functions execution hits the 1-hour TimeoutSeconds ceiling"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.ecommerce_pipeline.arn
  }

  alarm_actions = [aws_sns_topic.pipeline_alerts.arn]
}
