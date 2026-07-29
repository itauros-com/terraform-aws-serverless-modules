module "topics" {
  source = "../topic"

  for_each = var.topics

  prefix       = var.prefix
  name         = each.key
  display_name = each.value.display_name
  tags         = merge(local.tags, each.value.tags)

  fifo = each.value.fifo

  # If the topic has service publishers a CMK is required: the AWS-managed key cannot be used
  # by S3 or by EventBridge. The check lives in modules/topic.
  encryption = {
    managed    = each.value.kms_key_id != null || length(each.value.allow_publish_from) == 0
    kms_key_id = each.value.kms_key_id
  }

  # Subscriptions towards queues do not go through here: they are declared in `to_queues` and
  # inverted towards the queue side, where SQS requires fan-in from several topics to converge
  # into a single policy document.
  subscriptions      = each.value.subscriptions
  allow_publish_from = each.value.allow_publish_from

  alarms = {
    actions = local.alarm_actions
  }
}

module "queues" {
  source = "../queue"

  for_each = var.queues

  prefix = var.prefix
  name   = each.key
  tags   = merge(local.tags, each.value.tags)

  fifo                       = each.value.fifo
  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = each.value.message_retention_seconds
  receive_wait_time_seconds  = each.value.receive_wait_time_seconds
  delay_seconds              = each.value.delay_seconds
  encryption                 = { kms_key_id = each.value.kms_key_id }
  dlq                        = each.value.dlq

  # The result of the inversion: one entry per topic publishing onto this queue.
  subscriptions = local.queue_subscriptions[each.key]

  allow_send_from = concat(local.queue_bucket_sources[each.key], each.value.allow_send_from)

  alarms = {
    actions = local.alarm_actions
  }
}
