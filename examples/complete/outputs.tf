output "functions" {
  description = "The functions' names and log groups."
  value = {
    for k, m in {
      api           = module.api
      event_worker  = module.event_worker
      ingest_worker = module.ingest_worker
    } : k => { name = m.name, log_group = m.log_group_name }
  }
}

output "iam_decisions" {
  description = "Which cross-cutting permissions the function module attached to each function."
  value = {
    api           = module.api.iam
    event_worker  = module.event_worker.iam
    ingest_worker = module.ingest_worker.iam
  }
}

output "queue_policies" {
  description = <<-EOT
    The Sids of the statements in the queues' policies. On `events` there must be two, one per
    topic: it is the proof that the fan-in converged into a single document instead of producing
    two policies that overwrite each other.
  EOT
  value = {
    events = module.events.policy_statement_sids
    ingest = module.ingest.policy_statement_sids
  }
}

output "notifications" {
  description = "The notifications configured on the bucket, by destination."
  value       = module.documents.notification_ids
}

output "secret_value_in_state" {
  description = "Must be false: the secret's value does not go through Terraform."
  value       = module.database_secret.value_managed_by_terraform
}

output "api_policy" {
  description = "The policy generated from the HTTP function's grants, for inspection."
  value       = module.api.policy_json
}
