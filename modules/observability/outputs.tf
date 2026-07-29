output "alarm_topic_arn" {
  description = <<-EOT
    ARN of the alarm topic. To be passed to every other module's `alarms.actions`:

        module "jobs" {
          source = "…//modules/queue"
          alarms = { actions = [module.observability.alarm_topic_arn] }
        }

    It is the reason this module is declared before the others.
  EOT
  value       = local.topic_arn

  precondition {
    condition     = local.topic_arn != null
    error_message = "No topic for the alarms: set `alarm_topic.create = true` or pass `existing_alarm_topic_arn`."
  }

  precondition {
    condition     = !(var.alarm_topic.create && var.existing_alarm_topic_arn != null)
    error_message = "`alarm_topic.create` and `existing_alarm_topic_arn` conflict: pick one."
  }
}

output "dashboard_name" {
  description = "The dashboard's name. Null when it was not created, for example because no resource was declared."
  value       = local.has_dashboard ? aws_cloudwatch_dashboard.this[0].dashboard_name : null
}

output "dashboard_widget_count" {
  description = "How many widgets the dashboard contains. Zero means no resources to observe were declared."
  value       = length(local.widgets)
}

output "composite_alarm_arn" {
  description = "The composite alarm's ARN. Null when it is disabled."
  value       = var.composite_alarm.enabled ? aws_cloudwatch_composite_alarm.this[0].arn : null
}

output "shipped_log_groups" {
  description = "The log groups forwarded to the external destination, sorted."
  value       = var.log_shipping == null ? tolist([]) : sort(var.log_shipping.log_groups)
}
