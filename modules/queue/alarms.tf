resource "aws_cloudwatch_metric_alarm" "age" {
  count = var.alarms.enabled ? 1 : 0

  alarm_name = format("%s-age", local.base_name)
  alarm_description = format(
    "The oldest message in %s exceeded %d seconds: the consumers are not keeping up.",
    local.queue_name, var.alarms.age_threshold_seconds,
  )

  namespace   = "AWS/SQS"
  metric_name = "ApproximateAgeOfOldestMessage"
  statistic   = "Maximum"
  dimensions  = { QueueName = local.queue_name }

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarms.age_threshold_seconds
  period              = var.alarms.age_period
  evaluation_periods  = 1

  # An empty queue does not publish the metric: without this the alarm would sit in
  # INSUFFICIENT_DATA and would be ignored.
  treat_missing_data = "notBreaching"

  alarm_actions = var.alarms.actions
  ok_actions    = var.alarms.ok_actions

  tags = local.tags
}

# Any message in a DLQ is an incident: the threshold is one, not a percentage.
resource "aws_cloudwatch_metric_alarm" "dlq" {
  count = var.alarms.enabled && var.dlq.enabled ? 1 : 0

  alarm_name        = format("%s-dlq-not-empty", local.base_name)
  alarm_description = format("There are messages in the DLQ %s: something failed beyond the expected attempts.", local.dlq_name)

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  statistic   = "Maximum"
  dimensions  = { QueueName = local.dlq_name }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alarms.dlq_threshold
  period              = var.alarms.dlq_period
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarms.actions
  ok_actions    = var.alarms.ok_actions

  tags = local.tags
}
