output "arn" {
  description = "The job's ARN."
  value       = aws_glue_job.this.arn
}

output "name" {
  description = "The job's name, already prefixed. It is what StartJobRun takes."
  value       = aws_glue_job.this.name
}

output "registry_entry" {
  description = <<-EOT
    The entry for `resources.glue_jobs`, in the shape the registry expects, so that a
    function can be granted `"glue_job/<key>" = ["start"]` and receive the name through
    `env_from`.
  EOT
  value = {
    arn         = aws_glue_job.this.arn
    name        = aws_glue_job.this.name
    url         = null
    kms_key_arn = null
  }
}

output "role_arn" {
  description = "The job's role ARN."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "The job's role name, to attach policies from the outside."
  value       = aws_iam_role.this.name
}

output "log_group_name" {
  description = "The job's own log group, where continuous logging writes. Null for a Python shell job or with continuous logging off."
  value       = local.has_log_group ? aws_cloudwatch_log_group.this[0].name : null
}

output "connection_name" {
  description = "The Glue connection the module created. Null without `network`."
  value       = local.has_network ? aws_glue_connection.this[0].name : null
}

output "security_group_id" {
  description = <<-EOT
    The job's security group. Null without `network`. It is the source to let in on the
    database's security group: the job reaches the database from here.
  EOT
  value       = local.has_network ? module.security_group[0].id : null
}

output "failure_rule_arn" {
  description = "The EventBridge rule notifying failed runs. Null when the notification is off."
  value       = local.alarms.enabled ? aws_cloudwatch_event_rule.failed[0].arn : null
}

output "default_arguments" {
  description = "The job's effective arguments, with the references resolved and the managed ones included. Useful in tests and to know what the script receives."
  value       = local.default_arguments
}

output "policy_json" {
  description = "The inline policy of the role: grants, script, temp dir and extra statements. For inspection and tests."
  value       = module.grants.policy_json
}

output "iam" {
  description = <<-EOT
    Which permissions the module decided to give the role, beyond `AWSGlueServiceRole`,
    from the job's actual configuration. Inspectable without reading the state.
  EOT
  value = {
    temp_dir = var.temp_dir != null
    grants   = length(var.grants) > 0 || length(var.extra_policy_statements) > 0
    managed  = length(var.managed_policy_arns)
  }
}
