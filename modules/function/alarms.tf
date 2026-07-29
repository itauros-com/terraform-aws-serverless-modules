locals {
  alarms       = var.observability.alarms
  alarm_prefix = local.function_name

  # The p99 duration is compared against a fraction of the timeout, not against an
  # absolute value: that way the alarm stays correct when the timeout changes, and it
  # warns before the function starts being killed by the timeout.
  duration_threshold_ms = var.timeout * 1000 * local.alarms.duration_threshold_ratio
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  count = local.alarms.enabled ? 1 : 0

  alarm_name        = format("%s-errors", local.alarm_prefix)
  alarm_description = format("Function %s recorded errors.", local.function_name)

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  statistic   = "Sum"
  dimensions  = { FunctionName = module.lambda.lambda_function_name }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = local.alarms.error_threshold
  period              = local.alarms.error_period
  evaluation_periods  = 1

  # No invocations is not an error: without this the alarm would sit in
  # INSUFFICIENT_DATA on low-traffic functions and would be ignored.
  treat_missing_data = "notBreaching"

  alarm_actions = local.alarms.actions
  ok_actions    = local.alarms.ok_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "throttles" {
  count = local.alarms.enabled ? 1 : 0

  alarm_name        = format("%s-throttles", local.alarm_prefix)
  alarm_description = format("Function %s was throttled: insufficient reserved concurrency or account quota.", local.function_name)

  namespace   = "AWS/Lambda"
  metric_name = "Throttles"
  statistic   = "Sum"
  dimensions  = { FunctionName = module.lambda.lambda_function_name }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = local.alarms.throttle_threshold
  period              = local.alarms.throttle_period
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarms.actions
  ok_actions    = local.alarms.ok_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "duration" {
  count = local.alarms.enabled ? 1 : 0

  alarm_name = format("%s-duration", local.alarm_prefix)
  alarm_description = format(
    "The p99 duration of %s exceeded %.0f ms (%.0f%% of the %ds timeout).",
    local.function_name, local.duration_threshold_ms, local.alarms.duration_threshold_ratio * 100, var.timeout,
  )

  namespace          = "AWS/Lambda"
  metric_name        = "Duration"
  extended_statistic = "p99"
  dimensions         = { FunctionName = module.lambda.lambda_function_name }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = local.duration_threshold_ms
  period              = local.alarms.duration_period
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarms.actions
  ok_actions    = local.alarms.ok_actions

  tags = local.tags
}
