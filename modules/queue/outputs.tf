output "arn" {
  description = "The queue's ARN."
  value       = module.sqs.queue_arn
}

output "name" {
  description = "The queue's name, already prefixed and with the .fifo suffix if FIFO."
  value       = module.sqs.queue_name
}

output "url" {
  description = "The queue's URL, the one the SDKs need to receive and send."
  value       = module.sqs.queue_url
}

output "id" {
  description = "The queue's ID."
  value       = module.sqs.queue_id
}

output "dlq_arn" {
  description = "The DLQ's ARN. Null when the DLQ is disabled."
  value       = var.dlq.enabled ? module.sqs.dead_letter_queue_arn : null
}

output "dlq_name" {
  description = "The DLQ's name. Null when the DLQ is disabled."
  value       = var.dlq.enabled ? module.sqs.dead_letter_queue_name : null
}

output "dlq_url" {
  description = "The DLQ's URL, to reprocess the messages that ended up there. Null when the DLQ is disabled."
  value       = var.dlq.enabled ? module.sqs.dead_letter_queue_url : null
}

output "registry_entry" {
  description = <<-EOT
    The entry to put into the consumers' `resources` registry, already in the expected
    shape. It saves you from recomposing it by hand and forgetting the CMK, which is
    what makes the KMS permissions fail at runtime while the policy on the service is
    perfect.

        resources = { queues = { jobs = module.jobs.registry_entry } }
  EOT
  value = {
    arn         = module.sqs.queue_arn
    name        = module.sqs.queue_name
    url         = module.sqs.queue_url
    kms_key_arn = var.encryption.kms_key_id
  }
}

output "policy_statement_sids" {
  description = "The Sids of the statements in the queue's policy, sorted. Used to verify that fan-in from several sources converged into a single document."
  value       = sort(keys(local.policy_statements))
}

output "alarm_arns" {
  description = "The created alarms' ARNs, by type. An empty map when the alarms are disabled."
  value = var.alarms.enabled ? tomap(merge(
    { age = aws_cloudwatch_metric_alarm.age[0].arn },
    var.dlq.enabled ? { dlq = aws_cloudwatch_metric_alarm.dlq[0].arn } : {},
  )) : tomap({})
}
