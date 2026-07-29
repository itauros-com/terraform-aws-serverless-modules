output "arn" {
  description = "The function's ARN."
  value       = module.lambda.lambda_function_arn

  # The existence of the referenced resources is already checked by `env_from`'s
  # validations. What is caught here is the remaining case: the resource exists in
  # the registry but does not expose the requested attribute — for example `url` on a
  # bucket, or a `name` the caller never populated.
  precondition {
    condition = length(local.env_from_unresolved) == 0
    error_message = format(
      "env_from does not resolve: %s. The resource exists but the requested attribute is null: set it in `resources` or pick a different `attr`.",
      join(", ", local.env_from_unresolved),
    )
  }

  # A destination declared and not resolved is worse than none at all: the function
  # looks protected against losing asynchronous events and it is not.
  precondition {
    condition     = !local.has_async_target || local.async_on_failure_arn != null
    error_message = "async.on_failure is declared but resolves to no resource in the registry: check the key, or pass an explicit `arn`."
  }
}

output "name" {
  description = "The function's name, already prefixed."
  value       = module.lambda.lambda_function_name
}

output "invoke_arn" {
  description = "The invocation ARN, for API Gateway integrations."
  value       = module.lambda.lambda_function_invoke_arn
}

output "qualified_arn" {
  description = "The published version's ARN."
  value       = module.lambda.lambda_function_qualified_arn
}

output "version" {
  description = "The function's published version."
  value       = module.lambda.lambda_function_version
}

output "integration_entry" {
  description = <<-EOT
    The entry to pass to `modules/http-api` and to `modules/schedule`, already in the
    expected shape.

        functions = { api = module.api.integration_entry }

    It contains both `arn` and `invoke_arn` because they serve different purposes:
    the API integration wants `invoke_arn`, the invocation permission wants `arn`.
    Swapping them produces an error that does not name the cause.
  EOT
  value = {
    arn        = module.lambda.lambda_function_arn
    name       = module.lambda.lambda_function_name
    invoke_arn = module.lambda.lambda_function_invoke_arn
  }
}

output "role_arn" {
  description = "The execution role's ARN."
  value       = module.lambda.lambda_role_arn
}

output "role_name" {
  description = "The execution role's name, to attach policies from the outside."
  value       = module.lambda.lambda_role_name
}

output "log_group_name" {
  description = "The CloudWatch log group's name."
  value       = module.lambda.lambda_cloudwatch_log_group_name
}

output "log_group_arn" {
  description = "The CloudWatch log group's ARN, for subscription filters."
  value       = module.lambda.lambda_cloudwatch_log_group_arn
}

output "event_source_mapping_arns" {
  description = "The event source mappings' ARNs, by key."
  value       = module.lambda.lambda_event_source_mapping_arn
}

output "alarm_arns" {
  description = "The created alarms' ARNs, by type. An empty map when the alarms are disabled."

  # `tomap` on both branches: an output that changes type depending on the
  # configuration breaks callers iterating over it with for_each.
  value = local.alarms.enabled ? tomap({
    errors    = aws_cloudwatch_metric_alarm.errors[0].arn
    throttles = aws_cloudwatch_metric_alarm.throttles[0].arn
    duration  = aws_cloudwatch_metric_alarm.duration[0].arn
  }) : tomap({})
}

output "policy_json" {
  description = "The policy generated from the grants, for inspection and for tests. Null when there are no grants."
  value       = module.grants.policy_json
}

output "iam" {
  description = <<-EOT
    Which cross-cutting permissions the module decided to attach to the role, based
    on the function's actual configuration.

    This is not an implementation detail: `network` in particular is the difference
    between giving and not giving ENI permissions to a function, and it must be
    inspectable without reading the state — from the tests and from comparing
    policies during a migration.
  EOT
  value = {
    network = var.vpc != null
    tracing = var.observability.tracing
    async   = local.has_async_target
    grants  = local.has_policy
    managed = length(var.managed_policy_arns)
  }
}

output "environment_variables" {
  description = "The effective environment variables, with the references already resolved. Useful in tests and to understand what the function sees."
  value       = local.environment_variables
}
