output "arn" {
  description = "The topic's ARN."
  value       = module.sns.topic_arn

  # Service publishers cannot use the AWS-managed key: an S3 notification towards a
  # topic encrypted with alias/aws/sns fails with a KMSAccessDenied that appears
  # nowhere in Terraform, and the message is lost. Better to stop the plan.
  precondition {
    condition = length(var.allow_publish_from) == 0 || !local.uses_aws_managed_key
    error_message = format(
      "The topic authorizes the services [%s] to publish, but it is encrypted with the AWS-managed key: those services cannot use it and the publications will fail at runtime with KMSAccessDenied. Pass a CMK in `encryption.kms_key_id`, with a key policy that authorizes those services, or disable encryption with `encryption = { managed = false }`.",
      join(", ", [for a in var.allow_publish_from : a.service]),
    )
  }
}

output "name" {
  description = "The topic's name, already prefixed and with the .fifo suffix if FIFO."
  value       = module.sns.topic_name
}

output "id" {
  description = "The topic's ID."
  value       = module.sns.topic_id
}

output "registry_entry" {
  description = <<-EOT
    The entry to put into the publishers' `resources` registry, already in the expected
    shape, CMK included.

        resources = { topics = { events = module.events.registry_entry } }
  EOT
  value = {
    arn         = module.sns.topic_arn
    name        = module.sns.topic_name
    kms_key_arn = var.encryption.kms_key_id
  }
}

output "subscription_arns" {
  description = "The created subscriptions' ARNs, by key."
  value       = module.sns.subscriptions
}

output "policy_statement_sids" {
  description = "The Sids of the statements in the topic's policy, sorted. Empty when there are no service publishers and AWS's default applies."
  value       = sort(keys(local.policy_statements))
}

output "alarm_arns" {
  description = "The created alarms' ARNs, by type. An empty map when the alarms are disabled."
  value = var.alarms.enabled ? tomap({
    notifications_failed = aws_cloudwatch_metric_alarm.failed[0].arn
  }) : tomap({})
}
