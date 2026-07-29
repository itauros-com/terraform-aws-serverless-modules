# On HTTP APIs the server error metric is called `5xx`, not `5XXError` as on the REST APIs.
# The wrong name raises no error: it produces an alarm permanently in INSUFFICIENT_DATA,
# which looks like it is working.
resource "aws_cloudwatch_metric_alarm" "server_errors" {
  count = var.alarms.enabled ? 1 : 0

  alarm_name        = format("%s-5xx", local.api_name)
  alarm_description = format("Server errors on the API %s.", local.api_name)

  namespace   = "AWS/ApiGateway"
  metric_name = "5xx"
  statistic   = "Sum"
  dimensions = {
    ApiId = module.api.api_id
    Stage = var.stage_name
  }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alarms.server_error_threshold
  period              = var.alarms.server_error_period
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarms.actions
  ok_actions    = var.alarms.ok_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "latency" {
  count = var.alarms.enabled ? 1 : 0

  alarm_name = format("%s-latency", local.api_name)
  alarm_description = format(
    "The p99 latency of the API %s exceeded %d ms.", local.api_name, var.alarms.latency_threshold_ms,
  )

  namespace          = "AWS/ApiGateway"
  metric_name        = "Latency"
  extended_statistic = "p99"
  dimensions = {
    ApiId = module.api.api_id
    Stage = var.stage_name
  }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alarms.latency_threshold_ms
  period              = var.alarms.latency_period
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarms.actions
  ok_actions    = var.alarms.ok_actions

  tags = local.tags
}
