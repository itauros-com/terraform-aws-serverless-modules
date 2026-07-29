mock_provider "aws" {}

variables {
  prefix = "acme-prod"
  name   = "tenants"
}

run "table_with_a_partition_key_only" {
  command = plan

  variables {
    attributes = { id = "S" }
    hash_key   = "id"
  }

  # The naming assertion goes through the alarm's dimension and not through
  # `output.name`: the table's name is a computed attribute of the provider, hence
  # unknown at plan time, while the dimension comes from the configuration.
  assert {
    condition     = aws_cloudwatch_metric_alarm.read_throttle[0].dimensions["TableName"] == "acme-prod-tenants"
    error_message = "The final name must be <prefix>-<name>."
  }

  assert {
    condition     = output.stream_arn == null
    error_message = "Without a stream the output must be null."
  }

  assert {
    condition     = length(output.index_names) == 0
    error_message = "Without indexes the list must be empty."
  }
}

run "single_table_design_with_a_range_key_and_a_gsi" {
  command = plan

  variables {
    attributes = { pk = "S", sk = "S", gsi1pk = "S" }
    hash_key   = "pk"
    range_key  = "sk"

    global_secondary_indexes = {
      gsi1 = { hash_key = "gsi1pk", range_key = "sk" }
    }
  }

  # The previous wiring exposed neither range_key nor GSIs, so single-table design was
  # simply impossible.
  assert {
    condition     = output.index_names == tolist(["gsi1"])
    error_message = "The declared indexes must appear in the outputs."
  }
}

run "protections_enabled_by_default" {
  command = plan

  variables {
    attributes = { id = "S" }
    hash_key   = "id"
  }

  # Tables hold state: PITR is the only defence against a wrong application-level
  # deletion, and deletion protection against an absent-minded destroy. In the previous
  # wiring neither of the two could be exposed.
  assert {
    condition     = var.point_in_time_recovery.enabled == true
    error_message = "Point-in-time recovery must be enabled by default."
  }

  assert {
    condition     = var.deletion_protection == true
    error_message = "Deletion protection must be enabled by default."
  }
}

run "stream_can_be_enabled" {
  command = plan

  variables {
    attributes = { id = "S" }
    hash_key   = "id"
    stream     = { enabled = true }
  }

  assert {
    condition     = var.stream.view_type == "NEW_AND_OLD_IMAGES"
    error_message = "With the stream enabled the default view_type must allow computing a delta."
  }
}

run "ttl" {
  command = plan

  variables {
    attributes = { id = "S" }
    hash_key   = "id"
    ttl        = { enabled = true, attribute_name = "expires_at" }
  }

  assert {
    condition     = var.ttl.attribute_name == "expires_at"
    error_message = "The table with TTL must be created normally."
  }
}

run "registry_entry_with_a_cmk" {
  command = plan

  variables {
    attributes = { id = "S" }
    hash_key   = "id"
    encryption = { kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/abcd-1234" }
  }

  assert {
    condition     = output.registry_entry.kms_key_arn == "arn:aws:kms:eu-west-1:111122223333:key/abcd-1234"
    error_message = "The registry entry must carry the table's CMK."
  }
}

run "alarms_enabled_by_default" {
  command = plan

  variables {
    attributes = { id = "S" }
    hash_key   = "id"
  }

  assert {
    condition     = length(output.alarm_arns) == 3
    error_message = "There must be three alarms: read throttling, write throttling, system errors."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.read_throttle[0].dimensions["TableName"] == "acme-prod-tenants"
    error_message = "The alarms must point at the table by name."
  }
}

run "alarms_can_be_disabled" {
  command = plan

  variables {
    attributes = { id = "S" }
    hash_key   = "id"
    alarms     = { enabled = false }
  }

  assert {
    condition     = length(output.alarm_arns) == 0
    error_message = "alarms.enabled = false must create no alarm."
  }
}
