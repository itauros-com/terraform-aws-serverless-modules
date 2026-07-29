output "arn" {
  description = "The table's ARN."
  value       = module.dynamodb.dynamodb_table_arn

  # DynamoDB refuses the creation if a key attribute is not declared, or if a declared
  # attribute is used by no key. In both cases the service's error does not say which
  # attribute: here it does.
  # The message does not index the list: Terraform evaluates the expression even when
  # the condition is satisfied, and a `[0]` on an empty list would make the plan fail
  # in exactly the correct case.
  precondition {
    condition = length(local.undeclared_attributes) == 0
    error_message = format(
      "Attributes used by a key or by an index but not declared in `attributes`: %s. Add them with their type, for example `attributes = { pk = \"S\" }`.",
      join(", ", local.undeclared_attributes),
    )
  }

  precondition {
    condition = length(local.unused_attributes) == 0
    error_message = format(
      "Attributes declared in `attributes` but used by no key or index: %s. DynamoDB is schemaless: you declare only the attributes that take part in a key, and the others make the table's creation fail.",
      join(", ", local.unused_attributes),
    )
  }
}

output "name" {
  description = "The table's name, already prefixed."
  value       = module.dynamodb.dynamodb_table_id
}

output "id" {
  description = "The table's ID (identical to the name)."
  value       = module.dynamodb.dynamodb_table_id
}

output "stream_arn" {
  description = "The stream's ARN. Null when the stream is disabled."
  value       = var.stream.enabled ? module.dynamodb.dynamodb_table_stream_arn : null
}

output "stream_label" {
  description = "Timestamp identifying the stream. Null when the stream is disabled."
  value       = var.stream.enabled ? module.dynamodb.dynamodb_table_stream_label : null
}

output "registry_entry" {
  description = <<-EOT
    The entry to put into the consumers' `resources` registry, already in the expected
    shape, CMK included.

        resources = { tables = { tenants = module.tenants.registry_entry } }
  EOT
  value = {
    arn         = module.dynamodb.dynamodb_table_arn
    name        = module.dynamodb.dynamodb_table_id
    kms_key_arn = var.encryption.kms_key_arn
  }
}

output "index_names" {
  description = "Names of the secondary indexes, global and local, sorted."
  value       = sort(concat(keys(var.global_secondary_indexes), keys(var.local_secondary_indexes)))
}

output "alarm_arns" {
  description = "The created alarms' ARNs, by type. An empty map when the alarms are disabled."
  value = var.alarms.enabled ? tomap({
    read_throttle  = aws_cloudwatch_metric_alarm.read_throttle[0].arn
    write_throttle = aws_cloudwatch_metric_alarm.write_throttle[0].arn
    system_errors  = aws_cloudwatch_metric_alarm.system_errors[0].arn
  }) : tomap({})
}
