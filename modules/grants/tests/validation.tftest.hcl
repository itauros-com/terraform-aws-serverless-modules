# The defect this module exists to correct is silent failure: in the previous wiring
# a wrong reference did not stop the plan, it reached the Lambda as a literal string
# and was discovered at runtime. Here every reference error must stop the plan.

variables {
  resources = {
    buckets = {
      documents = { arn = "arn:aws:s3:::acme-prod-documents", name = "acme-prod-documents" }
    }
    queues = {
      emails = { arn = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-emails", name = "acme-prod-emails" }
    }
  }
}

run "key_without_a_type_prefix" {
  command = plan

  variables {
    grants = {
      documents = ["read"]
    }
  }

  expect_failures = [var.grants]
}

run "nonexistent_type_prefix" {
  command = plan

  variables {
    grants = {
      "kinesis/events" = ["read"]
    }
  }

  expect_failures = [var.grants]
}

run "empty_capability_list" {
  command = plan

  variables {
    grants = {
      "bucket/documents" = []
    }
  }

  expect_failures = [var.grants]
}

run "duplicate_capabilities" {
  command = plan

  variables {
    grants = {
      "bucket/documents" = ["read", "read"]
    }
  }

  expect_failures = [var.grants]
}

run "resource_not_in_the_registry" {
  command = plan

  variables {
    grants = {
      "bucket/nonexistent" = ["read"]
    }
  }

  expect_failures = [output.policy_json]
}

run "right_type_name_belonging_to_another_type" {
  command = plan

  # `emails` exists, but as a queue: referencing it as a bucket must fail, not
  # resolve by accident.
  variables {
    grants = {
      "bucket/emails" = ["read"]
    }
  }

  expect_failures = [output.policy_json]
}

run "capability_unknown_for_the_service" {
  command = plan

  variables {
    grants = {
      "bucket/documents" = ["scan"]
    }
  }

  expect_failures = [output.policy_json]
}

run "valid_capability_but_on_the_wrong_service" {
  command = plan

  # `consume` exists, but only for queues: on a bucket it has no meaning.
  variables {
    grants = {
      "bucket/documents" = ["consume"]
    }
  }

  expect_failures = [output.policy_json]
}

run "extra_statement_with_an_invalid_effect" {
  command = plan

  variables {
    grants = {}
    extra_statements = [
      { effect = "Permit", actions = ["ses:SendEmail"], resources = ["*"] }
    ]
  }

  expect_failures = [var.extra_statements]
}

run "extra_statement_without_resources" {
  command = plan

  variables {
    grants = {}
    extra_statements = [
      { actions = ["ses:SendEmail"], resources = [] }
    ]
  }

  expect_failures = [var.extra_statements]
}
