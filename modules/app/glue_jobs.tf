locals {
  glue_job_network = {
    for jk, j in var.glue_jobs : jk => j.network == null ? null : {
      subnet_id          = j.network.subnet_id
      security_group_ids = concat(local.glue_job_security_group_ids[jk], j.network.security_group_ids)
      jdbc               = j.network.jdbc
    }
  }

  # The alarm topic lets EventBridge publish only when some job notifies through it: an
  # application without jobs keeps the topic policy it always had.
  glue_job_alarms_enabled = anytrue([for j in values(var.glue_jobs) : j.observability.alarms.enabled])
}

module "glue_jobs" {
  source = "../glue-job"

  for_each = var.glue_jobs

  prefix      = var.prefix
  name        = each.key
  description = each.value.description
  tags        = merge(local.tags, each.value.tags)

  script   = each.value.script
  temp_dir = each.value.temp_dir

  command                = each.value.command
  glue_version           = each.value.glue_version
  python_version         = each.value.python_version
  worker_type            = each.value.worker_type
  number_of_workers      = each.value.number_of_workers
  max_capacity           = each.value.max_capacity
  timeout                = each.value.timeout
  max_retries            = each.value.max_retries
  max_concurrent_runs    = each.value.max_concurrent_runs
  execution_class        = each.value.execution_class
  security_configuration = each.value.security_configuration

  network     = local.glue_job_network[each.key]
  connections = each.value.connections

  resources               = local.resources
  args                    = each.value.args
  args_from               = each.value.args_from
  grants                  = each.value.grants
  extra_policy_statements = each.value.extra_policy_statements
  managed_policy_arns     = each.value.managed_policy_arns

  observability = {
    log_retention_days = each.value.observability.log_retention_days
    log_kms_key_id     = each.value.observability.log_kms_key_id
    continuous_logging = each.value.observability.continuous_logging
    metrics            = each.value.observability.metrics
    job_insights       = each.value.observability.job_insights
    alarms = {
      enabled = each.value.observability.alarms.enabled
      actions = local.alarm_actions
      states  = each.value.observability.alarms.states
    }
  }
}
