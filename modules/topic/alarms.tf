# SNS retries deliveries and then drops the message without informing the publisher:
# this metric is the only signal that something is not arriving.
resource "aws_cloudwatch_metric_alarm" "failed" {
  count = var.alarms.enabled ? 1 : 0

  alarm_name        = format("%s-notifications-failed", local.base_name)
  alarm_description = format("Failed deliveries on topic %s: SNS exhausted its attempts and discarded messages.", local.topic_name)

  namespace   = "AWS/SNS"
  metric_name = "NumberOfNotificationsFailed"
  statistic   = "Sum"
  dimensions  = { TopicName = local.topic_name }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alarms.failed_threshold
  period              = var.alarms.failed_period
  evaluation_periods  = 1

  # A topic with no traffic does not publish the metric.
  treat_missing_data = "notBreaching"

  alarm_actions = var.alarms.actions
  ok_actions    = var.alarms.ok_actions

  tags = local.tags
}
