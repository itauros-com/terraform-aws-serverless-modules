# The alarm topic is created here and not inside modules/observability, even though that
# module knows how to do it.
#
# The reason is ordering: every primitive needs its ARN for the `alarms.actions`, and
# modules/observability needs the primitives' names for the dashboard. Creating the topic in
# there would produce a cycle. Creating it here, the order is topic → primitives →
# observability, and modules/observability receives it as an existing topic.
module "alarm_topic" {
  source = "../topic"

  count = local.create_alarm_topic ? 1 : 0

  prefix       = var.prefix
  name         = "alarms"
  display_name = format("Alarms %s", var.prefix)
  tags         = local.tags

  # Encryption disabled unless an explicit CMK: CloudWatch cannot use the AWS-managed key, and
  # an alarm that fails to notify does not itself raise an alarm.
  encryption = {
    managed    = var.observability.alarm_topic_kms_key_id != null
    kms_key_id = var.observability.alarm_topic_kms_key_id
  }

  subscriptions = var.observability.alarm_subscriptions

  allow_publish_from = [
    { service = "cloudwatch", source_account = data.aws_caller_identity.current.account_id },
  ]

  # The alarm topic has no alarms of its own.
  alarms = { enabled = false }
}

data "aws_caller_identity" "current" {}

locals {
  # Every alarm the primitives created, for the composite alarm. The DLQs are included because
  # a message in a DLQ is the most useful thing to know.
  all_alarm_arns = flatten(concat(
    [for m in values(module.functions) : values(m.alarm_arns)],
    [for m in values(module.queues) : values(m.alarm_arns)],
    [for m in values(module.topics) : values(m.alarm_arns)],
    [for m in values(module.tables) : values(m.alarm_arns)],
    [for m in values(module.http_apis) : values(m.alarm_arns)],
  ))

  observed_log_groups = concat(
    [for m in values(module.functions) : m.log_group_name],
    compact([for m in values(module.http_apis) : m.access_log_group_name]),
  )
}

module "observability" {
  source = "../observability"

  count = var.observability.enabled ? 1 : 0

  prefix = var.prefix
  name   = "app"
  tags   = local.tags

  alarm_topic              = { create = false }
  existing_alarm_topic_arn = module.alarm_topic[0].arn

  dashboard_enabled = var.observability.dashboard_enabled

  functions = [for m in values(module.functions) : m.name]
  queues = flatten([
    for m in values(module.queues) : compact([m.name, m.dlq_name])
  ])
  tables = [for m in values(module.tables) : m.name]
  apis = [
    for k, m in module.http_apis : { id = m.id, stage = var.http_apis[k].stage_name }
  ]

  log_shipping = var.observability.log_shipping == null ? null : {
    destination_arn = var.observability.log_shipping.destination_arn
    role_arn        = var.observability.log_shipping.role_arn
    filter_pattern  = var.observability.log_shipping.filter_pattern
    log_groups      = local.observed_log_groups
  }

  composite_alarm = {
    enabled    = var.observability.composite_alarm_enabled
    alarm_arns = local.all_alarm_arns
  }
}
