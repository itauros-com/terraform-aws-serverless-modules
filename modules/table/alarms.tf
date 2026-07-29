# In on-demand mode throttling does not depend on the configured capacity but on
# partition limits: it happens when the keys are badly distributed. It is the signal
# that the data model needs revisiting, not that more capacity is needed.
resource "aws_cloudwatch_metric_alarm" "read_throttle" {
  count = var.alarms.enabled ? 1 : 0

  alarm_name        = format("%s-read-throttle", local.table_name)
  alarm_description = format("Throttled reads on %s: hot partitions or insufficient capacity.", local.table_name)

  namespace   = "AWS/DynamoDB"
  metric_name = "ReadThrottleEvents"
  statistic   = "Sum"
  dimensions  = { TableName = local.table_name }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alarms.throttle_threshold
  period              = var.alarms.throttle_period
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarms.actions
  ok_actions    = var.alarms.ok_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "write_throttle" {
  count = var.alarms.enabled ? 1 : 0

  alarm_name        = format("%s-write-throttle", local.table_name)
  alarm_description = format("Throttled writes on %s: hot partitions or insufficient capacity.", local.table_name)

  namespace   = "AWS/DynamoDB"
  metric_name = "WriteThrottleEvents"
  statistic   = "Sum"
  dimensions  = { TableName = local.table_name }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alarms.throttle_threshold
  period              = var.alarms.throttle_period
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarms.actions
  ok_actions    = var.alarms.ok_actions

  tags = local.tags
}

# Errors on the AWS side: they are not the application's fault, but if they persist
# the requests are failing and the client sees them as a generic error.
resource "aws_cloudwatch_metric_alarm" "system_errors" {
  count = var.alarms.enabled ? 1 : 0

  alarm_name        = format("%s-system-errors", local.table_name)
  alarm_description = format("System errors on %s.", local.table_name)

  namespace   = "AWS/DynamoDB"
  metric_name = "SystemErrors"
  statistic   = "Sum"
  dimensions  = { TableName = local.table_name }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alarms.error_threshold
  period              = var.alarms.error_period
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarms.actions
  ok_actions    = var.alarms.ok_actions

  tags = local.tags
}
