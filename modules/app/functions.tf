locals {
  # Security groups are referenced by key, with a separate list for literal ids. This is not a
  # `try(module[...], literal)`: that pattern would resolve a typo into a literal string, which
  # is exactly the silent failure this library exists to eliminate. A key that does not exist
  # appears in `wiring_errors` and stops the plan.
  function_vpc = {
    for fk, f in var.functions : fk => f.vpc == null ? null : {
      subnet_ids         = f.vpc.subnet_ids
      security_group_ids = concat(local.function_security_group_ids[fk], f.vpc.security_group_ids)
    }
  }
}

module "functions" {
  source = "../function"

  for_each = var.functions

  prefix      = var.prefix
  name        = each.key
  description = each.value.description
  tags        = merge(local.tags, each.value.tags)

  image_uri           = each.value.image
  package             = each.value.package
  ignore_code_changes = each.value.ignore_code_changes

  runtime       = each.value.runtime
  handler       = each.value.handler
  architectures = each.value.architectures
  layers        = each.value.layers

  memory_size                    = each.value.memory_size
  timeout                        = each.value.timeout
  ephemeral_storage_size         = each.value.ephemeral_storage_size
  reserved_concurrent_executions = each.value.reserved_concurrent_executions

  vpc = local.function_vpc[each.key]

  resources               = local.resources
  env                     = each.value.env
  env_from                = each.value.env_from
  grants                  = each.value.grants
  extra_policy_statements = each.value.extra_policy_statements
  managed_policy_arns     = each.value.managed_policy_arns

  event_sources = each.value.event_sources

  async = {
    enabled                      = each.value.async.enabled
    maximum_retry_attempts       = each.value.async.maximum_retry_attempts
    maximum_event_age_in_seconds = each.value.async.maximum_event_age_in_seconds
    on_failure                   = local.function_async_on_failure[each.key]
  }

  observability = {
    log_retention_days = each.value.observability.log_retention_days
    log_kms_key_id     = each.value.observability.log_kms_key_id
    log_format         = each.value.observability.log_format
    log_level          = each.value.observability.log_level
    system_log_level   = each.value.observability.system_log_level
    tracing            = each.value.observability.tracing
    alarms = {
      enabled                  = each.value.observability.alarms.enabled
      actions                  = local.alarm_actions
      error_threshold          = each.value.observability.alarms.error_threshold
      error_period             = each.value.observability.alarms.error_period
      throttle_threshold       = each.value.observability.alarms.throttle_threshold
      throttle_period          = each.value.observability.alarms.throttle_period
      duration_threshold_ratio = each.value.observability.alarms.duration_threshold_ratio
      duration_period          = each.value.observability.alarms.duration_period
    }
  }

  # The invocation permissions from API Gateway are created by the API, which is the only one
  # that knows its own execution ARN. There is no need to declare them here.
  allowed_triggers = {}
}
