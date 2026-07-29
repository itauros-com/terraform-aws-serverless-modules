data "aws_region" "current" {}

locals {
  app_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.app_name })

  region = coalesce(var.region, data.aws_region.current.region)

  create_topic = var.alarm_topic.create && var.existing_alarm_topic_arn == null
  topic_arn    = local.create_topic ? module.alarm_topic[0].arn : var.existing_alarm_topic_arn

  # ----------------------------------------------------------------------------
  # Dashboard
  #
  # The widgets are built per resource type and not per resource: one error line with all
  # the functions overlaid shows at once which one is failing, whereas twenty separate
  # widgets have to be hunted through one by one.
  # ----------------------------------------------------------------------------

  lambda_widgets = length(var.functions) == 0 ? [] : [
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "Lambda — errors and throttles"
        region = local.region
        stat   = "Sum"
        period = 300
        view   = "timeSeries"
        metrics = concat(
          [for f in var.functions : ["AWS/Lambda", "Errors", "FunctionName", f]],
          [for f in var.functions : ["AWS/Lambda", "Throttles", "FunctionName", f]],
        )
      }
    },
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title   = "Lambda — p99 duration"
        region  = local.region
        stat    = "p99"
        period  = 300
        view    = "timeSeries"
        metrics = [for f in var.functions : ["AWS/Lambda", "Duration", "FunctionName", f]]
      }
    },
  ]

  # The age of the oldest message tells whether the consumers are keeping up; queue depth
  # grows for a spike absorbed perfectly well too.
  queue_widgets = length(var.queues) == 0 ? [] : [
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title   = "SQS — age of the oldest message"
        region  = local.region
        stat    = "Maximum"
        period  = 300
        view    = "timeSeries"
        metrics = [for q in var.queues : ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", q]]
      }
    },
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title   = "SQS — visible messages"
        region  = local.region
        stat    = "Maximum"
        period  = 300
        view    = "timeSeries"
        metrics = [for q in var.queues : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", q]]
      }
    },
  ]

  table_widgets = length(var.tables) == 0 ? [] : [
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "DynamoDB — throttles"
        region = local.region
        stat   = "Sum"
        period = 300
        view   = "timeSeries"
        metrics = concat(
          [for t in var.tables : ["AWS/DynamoDB", "ReadThrottleEvents", "TableName", t]],
          [for t in var.tables : ["AWS/DynamoDB", "WriteThrottleEvents", "TableName", t]],
        )
      }
    },
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "DynamoDB — consumed capacity"
        region = local.region
        stat   = "Sum"
        period = 300
        view   = "timeSeries"
        metrics = concat(
          [for t in var.tables : ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", t]],
          [for t in var.tables : ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", t]],
        )
      }
    },
  ]

  api_widgets = length(var.apis) == 0 ? [] : [
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "API Gateway — requests and errors"
        region = local.region
        stat   = "Sum"
        period = 300
        view   = "timeSeries"
        metrics = concat(
          [for a in var.apis : ["AWS/ApiGateway", "Count", "ApiId", a.id, "Stage", a.stage]],
          [for a in var.apis : ["AWS/ApiGateway", "5xx", "ApiId", a.id, "Stage", a.stage]],
          [for a in var.apis : ["AWS/ApiGateway", "4xx", "ApiId", a.id, "Stage", a.stage]],
        )
      }
    },
    {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title   = "API Gateway — p99 latency"
        region  = local.region
        stat    = "p99"
        period  = 300
        view    = "timeSeries"
        metrics = [for a in var.apis : ["AWS/ApiGateway", "Latency", "ApiId", a.id, "Stage", a.stage]]
      }
    },
  ]

  widgets = concat(local.api_widgets, local.lambda_widgets, local.queue_widgets, local.table_widgets)

  # Lays the widgets out in two columns without having to compute their coordinates by
  # hand.
  positioned_widgets = [
    for i, w in local.widgets : merge(w, {
      x = (i % 2) * 12
      y = floor(i / 2) * 6
    })
  ]

  has_dashboard = var.dashboard_enabled && length(local.widgets) > 0
}

module "alarm_topic" {
  source = "../topic"

  count = local.create_topic ? 1 : 0

  prefix       = var.prefix
  name         = format("%s-alarms", var.name)
  display_name = format("Alarms %s", local.app_name)
  tags         = var.tags

  # `managed = false` and not the default: CloudWatch cannot use the AWS-managed key, and
  # an alarm that fails to notify does not itself raise an alarm.
  encryption = {
    managed    = var.alarm_topic.kms_key_id != null
    kms_key_id = var.alarm_topic.kms_key_id
  }

  subscriptions = var.alarm_topic.subscriptions

  allow_publish_from = [
    { service = "cloudwatch", source_account = data.aws_caller_identity.current.account_id },
  ]

  # The alarm topic has no alarms of its own: that would be bottomless recursion.
  alarms = { enabled = false }
}

data "aws_caller_identity" "current" {}

resource "aws_cloudwatch_dashboard" "this" {
  count = local.has_dashboard ? 1 : 0

  dashboard_name = local.app_name
  dashboard_body = jsonencode({ widgets = local.positioned_widgets })
}

resource "aws_cloudwatch_log_subscription_filter" "this" {
  for_each = var.log_shipping == null ? toset([]) : toset(var.log_shipping.log_groups)

  name            = format("%s-shipping", local.app_name)
  log_group_name  = each.value
  filter_pattern  = var.log_shipping.filter_pattern
  destination_arn = var.log_shipping.destination_arn
  role_arn        = var.log_shipping.role_arn
}

resource "aws_cloudwatch_composite_alarm" "this" {
  count = var.composite_alarm.enabled ? 1 : 0

  alarm_name        = format("%s-unhealthy", local.app_name)
  alarm_description = format("At least one alarm of %s is firing.", local.app_name)

  alarm_rule = join(" OR ", [for a in var.composite_alarm.alarm_arns : format("ALARM(%s)", a)])

  alarm_actions = compact([local.topic_arn])
  ok_actions    = compact([local.topic_arn])

  tags = local.tags
}
