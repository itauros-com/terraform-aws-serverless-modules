locals {
  base_name  = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)
  topic_name = var.fifo.enabled ? format("%s.fifo", local.base_name) : local.base_name

  tags = merge(var.tags, { Name = local.topic_name })

  # The AWS-managed key has no cost, so it is the default. It stays explicit that it
  # is not the same thing as a CMK: service publishers cannot use it (see the
  # precondition on the `arn` output).
  kms_key_id           = var.encryption.kms_key_id != null ? var.encryption.kms_key_id : (var.encryption.managed ? "alias/aws/sns" : null)
  uses_aws_managed_key = var.encryption.kms_key_id == null && var.encryption.managed

  service_statements = {
    for idx, a in var.allow_publish_from : format(
      "%sPublish%d", replace(title(replace(a.service, "/[^0-9A-Za-z]+/", " ")), " ", ""), idx
      ) => {
      effect     = "Allow"
      actions    = ["sns:Publish"]
      principals = [{ type = "Service", identifiers = [format("%s.amazonaws.com", a.service)] }]
      condition = a.source_arn != null ? [
        { test = "ArnLike", variable = "aws:SourceArn", values = [a.source_arn] }
        ] : [
        { test = "StringEquals", variable = "aws:SourceAccount", values = [a.source_account] }
      ]
    }
  }

  policy_statements = merge(local.service_statements, var.extra_policy_statements)

  # Derived from the shape of the inputs: it feeds a `count` in the upstream module.
  has_policy = length(local.policy_statements) > 0
}

module "sns" {
  source  = "terraform-aws-modules/sns/aws"
  version = "~> 6.0"

  name         = local.topic_name
  display_name = var.display_name
  tags         = local.tags

  fifo_topic                  = var.fifo.enabled
  content_based_deduplication = var.fifo.enabled ? var.fifo.content_based_deduplication : null
  fifo_throughput_scope       = var.fifo.enabled ? var.fifo.throughput_scope : null
  archive_policy              = var.archive_policy

  kms_master_key_id = local.kms_key_id
  delivery_policy   = var.delivery_policy
  tracing_config    = var.tracing_config

  # The policy is created only when there is something to authorize. Without a policy
  # AWS's default behaviour applies: only the account owner publishes.
  # `enable_default_topic_policy` keeps that access even when service publishers are
  # added.
  create_topic_policy         = local.has_policy
  enable_default_topic_policy = true
  topic_policy_statements     = local.has_policy ? local.policy_statements : {}

  create_subscription = length(var.subscriptions) > 0
  subscriptions = {
    for k, s in var.subscriptions : k => merge(
      {
        protocol = s.protocol
        endpoint = s.endpoint
      },
      s.filter_policy != null ? { filter_policy = s.filter_policy, filter_policy_scope = s.filter_policy_scope } : {},
      s.raw_message_delivery != null ? { raw_message_delivery = s.raw_message_delivery } : {},
      s.delivery_policy != null ? { delivery_policy = s.delivery_policy } : {},
      s.redrive_policy != null ? { redrive_policy = s.redrive_policy } : {},
      s.replay_policy != null ? { replay_policy = s.replay_policy } : {},
      s.subscription_role_arn != null ? { subscription_role_arn = s.subscription_role_arn } : {},
    )
  }
}
