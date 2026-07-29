mock_provider "aws" {}

variables {
  prefix = "acme-prod"
  name   = "tenants"
}

run "undeclared_hash_key" {
  command = plan

  variables {
    attributes = { other = "S" }
    hash_key   = "id"
  }

  # DynamoDB refuses the creation but does not say which attribute is missing.
  expect_failures = [output.arn]
}

run "undeclared_range_key" {
  command = plan

  variables {
    attributes = { pk = "S" }
    hash_key   = "pk"
    range_key  = "sk"
  }

  expect_failures = [output.arn]
}

run "undeclared_index_key" {
  command = plan

  variables {
    attributes = { pk = "S", sk = "S" }
    hash_key   = "pk"
    range_key  = "sk"

    global_secondary_indexes = {
      gsi1 = { hash_key = "gsi1pk" }
    }
  }

  expect_failures = [output.arn]
}

run "attribute_declared_and_unused" {
  command = plan

  variables {
    attributes = { pk = "S", useless = "S" }
    hash_key   = "pk"
  }

  # This is the inverse mistake and just as fatal: DynamoDB is schemaless, and an
  # attribute declared without taking part in a key makes the creation fail.
  expect_failures = [output.arn]
}

run "invalid_attribute_type" {
  command = plan

  variables {
    attributes = { id = "string" }
    hash_key   = "id"
  }

  expect_failures = [var.attributes]
}

run "projection_include_without_attributes" {
  command = plan

  variables {
    attributes = { pk = "S", gsi1pk = "S" }
    hash_key   = "pk"

    global_secondary_indexes = {
      gsi1 = { hash_key = "gsi1pk", projection_type = "INCLUDE" }
    }
  }

  expect_failures = [var.global_secondary_indexes]
}

run "non_key_attributes_on_projection_all" {
  command = plan

  variables {
    attributes = { pk = "S", gsi1pk = "S" }
    hash_key   = "pk"

    global_secondary_indexes = {
      gsi1 = { hash_key = "gsi1pk", projection_type = "ALL", non_key_attributes = ["name"] }
    }
  }

  expect_failures = [var.global_secondary_indexes]
}

run "nonexistent_projection_type" {
  command = plan

  variables {
    attributes = { pk = "S", gsi1pk = "S" }
    hash_key   = "pk"

    global_secondary_indexes = {
      gsi1 = { hash_key = "gsi1pk", projection_type = "PARTIAL" }
    }
  }

  expect_failures = [var.global_secondary_indexes]
}

run "nonexistent_billing_mode" {
  command = plan

  variables {
    attributes   = { id = "S" }
    hash_key     = "id"
    billing_mode = "ON_DEMAND"
  }

  expect_failures = [var.billing_mode]
}

run "invalid_stream_view_type" {
  command = plan

  variables {
    attributes = { id = "S" }
    hash_key   = "id"
    stream     = { enabled = true, view_type = "FULL" }
  }

  expect_failures = [var.stream]
}

run "invalid_table_class" {
  command = plan

  variables {
    attributes  = { id = "S" }
    hash_key    = "id"
    table_class = "GLACIER"
  }

  expect_failures = [var.table_class]
}
