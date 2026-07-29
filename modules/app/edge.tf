module "http_apis" {
  source = "../http-api"

  for_each = var.http_apis

  prefix      = var.prefix
  name        = each.key
  description = each.value.description
  tags        = merge(local.tags, each.value.tags)

  # All the functions are integrable: which ones are actually needed is said by the routes and
  # the authorizers, and the module creates a permission only for the ones actually
  # referenced.
  functions = { for fk, m in module.functions : fk => m.integration_entry }

  routes      = each.value.routes
  authorizers = each.value.authorizers
  cors        = each.value.cors
  domain      = each.value.domain

  stage_name               = each.value.stage_name
  throttling               = each.value.throttling
  access_logs              = each.value.access_logs
  disable_default_endpoint = each.value.disable_default_endpoint

  alarms = {
    enabled                = each.value.alarms.enabled
    actions                = local.alarm_actions
    server_error_threshold = each.value.alarms.server_error_threshold
    server_error_period    = each.value.alarms.server_error_period
    latency_threshold_ms   = each.value.alarms.latency_threshold_ms
    latency_period         = each.value.alarms.latency_period
  }
}

module "sites" {
  source = "../site"

  for_each = var.sites

  prefix  = var.prefix
  name    = each.key
  comment = each.value.comment
  tags    = merge(local.tags, each.value.tags)

  aliases         = each.value.aliases
  certificate_arn = each.value.certificate_arn
  web_acl_arn     = each.value.web_acl_arn
  zone_id         = each.value.zone_id

  spa                        = each.value.spa
  default_root_object        = each.value.default_root_object
  price_class                = each.value.price_class
  cache_policy_id            = each.value.cache_policy_id
  response_headers_policy_id = each.value.response_headers_policy_id
  allowed_methods            = each.value.allowed_methods
  bucket_force_destroy       = each.value.bucket_force_destroy
  wait_for_deployment        = each.value.wait_for_deployment
}

module "registries" {
  source = "../registry"

  for_each = var.registries

  prefix = var.prefix
  name   = each.key
  tags   = merge(local.tags, each.value.tags)

  immutable_tags        = each.value.immutable_tags
  mutable_tag_patterns  = each.value.mutable_tag_patterns
  scan_on_push          = each.value.scan_on_push
  kms_key_arn           = each.value.kms_key_arn
  force_delete          = each.value.force_delete
  untagged_expire_days  = each.value.untagged_expire_days
  keep_tagged_images    = each.value.keep_tagged_images
  retained_tag_prefixes = each.value.retained_tag_prefixes

  read_access_arns = each.value.read_access_arns
  lambda_read_access_arns = [
    for fk in each.value.lambda_read_access_functions : module.functions[fk].arn
    if contains(keys(var.functions), fk)
  ]
}

module "schedules" {
  source = "../schedule"

  for_each = local.valid_schedules

  prefix      = var.prefix
  name        = each.key
  description = each.value.description
  tags        = merge(local.tags, each.value.tags)

  expression = each.value.expression
  timezone   = each.value.timezone
  enabled    = each.value.enabled
  group_name = each.value.group_name

  # The `try`s route a wrong reference to `wiring`'s precondition, which reports it with the
  # key and the place where it is declared, instead of surfacing as an "Invalid index" on this
  # module block.
  target = {
    function_arn      = try(module.functions[each.value.target_function].arn, null)
    queue_arn         = try(module.queues[each.value.target_queue].arn, null)
    state_machine_arn = each.value.target_state_machine_arn
    input             = each.value.input
    message_group_id  = each.value.message_group_id

    # The type is known here, where the target is declared by key: passing it makes it readable
    # in the plan which permission the schedule's role receives.
    type = local.schedule_target_types[each.key]
  }

  # The named queue's DLQ, not the queue itself: a scheduled invocation that fails goes into
  # the dead letter queue, not back into the working one.
  dead_letter_arn           = try(module.queues[each.value.dead_letter_queue].dlq_arn, null)
  allow_missing_dead_letter = each.value.allow_missing_dead_letter

  retry                        = each.value.retry
  flexible_time_window_minutes = each.value.flexible_time_window_minutes
  start_date                   = each.value.start_date
  end_date                     = each.value.end_date
}
