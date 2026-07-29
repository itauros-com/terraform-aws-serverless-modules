locals {
  base_name  = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)
  queue_name = var.fifo.enabled ? format("%s.fifo", local.base_name) : local.base_name
  dlq_name   = var.fifo.enabled ? format("%s-dlq.fifo", local.base_name) : format("%s-dlq", local.base_name)

  tags = merge(var.tags, { Name = local.queue_name })

  # One statement per source, in a single document. SQS allows a single `Policy`
  # attribute per queue: emitting one policy per subscription would leave only the
  # last write alive, silently. The upstream module accepts a map of statements and
  # merges them into one document, so fan-in is correct by construction.
  #
  # `resources` is deliberately left null: upstream resolves it to the queue's ARN,
  # avoiding the chicken-and-egg problem.
  subscription_statements = {
    for k, s in var.subscriptions : format("SnsFrom%s", replace(title(replace(k, "/[^0-9A-Za-z]+/", " ")), " ", "")) => {
      effect     = "Allow"
      actions    = ["sqs:SendMessage"]
      principals = [{ type = "Service", identifiers = ["sns.amazonaws.com"] }]
      condition  = [{ test = "ArnEquals", variable = "aws:SourceArn", values = [s.topic_arn] }]
    }
  }

  service_statements = {
    for idx, a in var.allow_send_from : format(
      "%sFrom%d", replace(title(replace(a.service, "/[^0-9A-Za-z]+/", " ")), " ", ""), idx
      ) => {
      effect     = "Allow"
      actions    = ["sqs:SendMessage"]
      principals = [{ type = "Service", identifiers = [format("%s.amazonaws.com", a.service)] }]
      condition = a.source_arn != null ? [
        { test = "ArnLike", variable = "aws:SourceArn", values = [a.source_arn] }
        ] : [
        { test = "StringEquals", variable = "aws:SourceAccount", values = [a.source_account] }
      ]
    }
  }

  policy_statements = merge(
    local.subscription_statements,
    local.service_statements,
    var.extra_policy_statements,
  )

  # Derived from the shape of the inputs, so it is known at plan time: it feeds a
  # `count` in the upstream module.
  has_policy = length(local.policy_statements) > 0

  # Upstream computes `deadLetterTargetArn` itself from the DLQ it creates and uses
  # maxReceiveCount = 5 as its default: only the override is passed here. With the DLQ
  # disabled it must stay empty, otherwise upstream would try to write a redrive
  # policy with no destination.
  #
  # `tomap` on both branches because the two sides of a conditional must have the same
  # type.
  redrive_policy = var.dlq.enabled ? tomap({ maxReceiveCount = var.dlq.max_receive_count }) : tomap({})
}

module "sqs" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "~> 5.0"

  name = local.queue_name
  tags = local.tags

  fifo_queue                  = var.fifo.enabled
  content_based_deduplication = var.fifo.enabled ? var.fifo.content_based_deduplication : null
  deduplication_scope         = var.fifo.enabled ? var.fifo.deduplication_scope : null
  fifo_throughput_limit       = var.fifo.enabled ? var.fifo.throughput_limit : null

  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = var.receive_wait_time_seconds
  delay_seconds              = var.delay_seconds
  max_message_size           = var.max_message_size

  kms_master_key_id                 = var.encryption.kms_key_id
  kms_data_key_reuse_period_seconds = var.encryption.kms_data_key_reuse_period_seconds
  sqs_managed_sse_enabled           = var.encryption.kms_key_id != null ? null : var.encryption.managed

  # Without `maxReceiveCount` the redrive is not configured: the DLQ exists and stays
  # empty forever, while the messages are retried until they expire.
  create_dlq                     = var.dlq.enabled
  dlq_name                       = var.dlq.enabled ? local.dlq_name : null
  dlq_message_retention_seconds  = var.dlq.enabled ? var.dlq.message_retention_seconds : null
  dlq_visibility_timeout_seconds = var.dlq.visibility_timeout_seconds
  redrive_policy                 = local.redrive_policy

  # Limits which queues can spill messages into this DLQ. Upstream sets `byQueue`
  # itself with this queue as the only source; without it, any queue in the account
  # could use it.
  create_dlq_redrive_allow_policy = var.dlq.enabled

  create_queue_policy     = local.has_policy
  queue_policy_statements = local.has_policy ? local.policy_statements : null
}

resource "aws_sns_topic_subscription" "this" {
  for_each = var.subscriptions

  topic_arn = each.value.topic_arn
  protocol  = "sqs"
  endpoint  = module.sqs.queue_arn

  filter_policy        = each.value.filter_policy
  filter_policy_scope  = each.value.filter_policy != null ? each.value.filter_policy_scope : null
  raw_message_delivery = each.value.raw_message_delivery
}
