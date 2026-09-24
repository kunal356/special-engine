resource "aws_sns_topic" "pipeline_alerts" {
  name = "${var.project_name}-pipeline-alerts"
}

# Only created if you set var.alert_email - otherwise the topic still
# exists and you can subscribe to it manually (email, Slack via chatbot,
# PagerDuty, etc.) without touching Terraform.
resource "aws_sns_topic_subscription" "pipeline_alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.pipeline_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
