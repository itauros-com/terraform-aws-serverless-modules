module "tables" {
  source = "../table"

  for_each = var.tables

  prefix = var.prefix
  name   = each.key
  tags   = merge(local.tags, each.value.tags)

  attributes = each.value.attributes
  hash_key   = each.value.hash_key
  range_key  = each.value.range_key

  billing_mode   = each.value.billing_mode
  read_capacity  = each.value.read_capacity
  write_capacity = each.value.write_capacity
  table_class    = each.value.table_class

  global_secondary_indexes = each.value.global_secondary_indexes
  local_secondary_indexes  = each.value.local_secondary_indexes

  ttl                    = each.value.ttl
  point_in_time_recovery = each.value.point_in_time_recovery
  deletion_protection    = each.value.deletion_protection
  stream                 = each.value.stream
  encryption             = { kms_key_arn = each.value.kms_key_arn }

  alarms = {
    actions = local.alarm_actions
  }
}

module "secrets" {
  source = "../secret"

  for_each = var.secrets

  prefix = var.prefix
  name   = each.key
  tags   = merge(local.tags, each.value.tags)

  description             = each.value.description
  kms_key_id              = each.value.kms_key_id
  recovery_window_in_days = each.value.recovery_window_in_days
  initial_value           = each.value.initial_value
  ignore_value_changes    = each.value.ignore_value_changes
}

# The buckets are created after the functions, because the notifications need them. The
# functions, conversely, do not depend on this module: the bucket registry is computed from
# the prefix, and that is how the cycle is broken.
module "buckets" {
  source = "../bucket"

  for_each = var.buckets

  prefix = var.prefix
  name   = each.key
  tags   = merge(local.tags, each.value.tags)

  versioning_enabled = each.value.versioning_enabled
  encryption         = { kms_key_arn = each.value.kms_key_arn }
  force_destroy      = each.value.force_destroy
  object_ownership   = each.value.object_ownership
  cors_rules         = each.value.cors_rules
  lifecycle_rules    = each.value.lifecycle_rules
  logging            = each.value.logging

  notifications = {
    queues = {
      for nk, n in local.bucket_notifications[each.key].queues : nk => {
        queue_arn     = module.queues[n.queue].arn
        events        = n.events
        filter_prefix = n.filter_prefix
        filter_suffix = n.filter_suffix
      }
    }
    topics = {
      for nk, n in local.bucket_notifications[each.key].topics : nk => {
        topic_arn     = module.topics[n.topic].arn
        events        = n.events
        filter_prefix = n.filter_prefix
        filter_suffix = n.filter_suffix
      }
    }
    functions = {
      for nk, n in local.bucket_notifications[each.key].functions : nk => {
        function_arn  = module.functions[n.function].arn
        events        = n.events
        filter_prefix = n.filter_prefix
        filter_suffix = n.filter_suffix
      }
    }
  }
}
