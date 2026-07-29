locals {
  table_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.table_name })

  provisioned = var.billing_mode == "PROVISIONED"

  # Every attribute referenced by a key or by an index must be declared in
  # `attributes`. If one is missing, DynamoDB refuses the creation with an error that
  # does not say which attribute: the check lives in the outputs' preconditions, with
  # the name.
  key_attributes = distinct(compact(concat(
    [var.hash_key, var.range_key],
    [for i in values(var.global_secondary_indexes) : i.hash_key],
    [for i in values(var.global_secondary_indexes) : i.range_key],
    [for i in values(var.local_secondary_indexes) : i.range_key],
  )))

  undeclared_attributes = sort([
    for a in local.key_attributes : a if !contains(keys(var.attributes), a)
  ])

  # The converse is just as fatal: an attribute declared and used by no key makes the
  # table's creation fail.
  unused_attributes = sort([
    for a in keys(var.attributes) : a if !contains(local.key_attributes, a)
  ])

  attributes = [for name, type in var.attributes : { name = name, type = type }]

  global_secondary_indexes = [
    for name, i in var.global_secondary_indexes : {
      name               = name
      hash_key           = i.hash_key
      range_key          = i.range_key
      projection_type    = i.projection_type
      non_key_attributes = i.non_key_attributes
      read_capacity      = local.provisioned ? i.read_capacity : null
      write_capacity     = local.provisioned ? i.write_capacity : null
    }
  ]

  local_secondary_indexes = [
    for name, i in var.local_secondary_indexes : {
      name               = name
      range_key          = i.range_key
      projection_type    = i.projection_type
      non_key_attributes = i.non_key_attributes
    }
  ]
}

module "dynamodb" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 5.0"

  name = local.table_name
  tags = local.tags

  hash_key   = var.hash_key
  range_key  = var.range_key
  attributes = local.attributes

  billing_mode   = var.billing_mode
  read_capacity  = local.provisioned ? var.read_capacity : null
  write_capacity = local.provisioned ? var.write_capacity : null
  table_class    = var.table_class

  global_secondary_indexes = local.global_secondary_indexes
  local_secondary_indexes  = local.local_secondary_indexes

  ttl_enabled        = var.ttl.enabled
  ttl_attribute_name = var.ttl.enabled ? var.ttl.attribute_name : ""

  point_in_time_recovery_enabled        = var.point_in_time_recovery.enabled
  point_in_time_recovery_period_in_days = var.point_in_time_recovery.enabled ? var.point_in_time_recovery.period_in_days : null

  deletion_protection_enabled = var.deletion_protection

  stream_enabled   = var.stream.enabled
  stream_view_type = var.stream.enabled ? var.stream.view_type : null

  server_side_encryption_enabled     = var.encryption.kms_key_arn != null
  server_side_encryption_kms_key_arn = var.encryption.kms_key_arn

  autoscaling_enabled  = local.provisioned && var.autoscaling.enabled
  autoscaling_defaults = var.autoscaling.defaults
  autoscaling_read     = var.autoscaling.read
  autoscaling_write    = var.autoscaling.write
  autoscaling_indexes  = var.autoscaling.indexes
}
