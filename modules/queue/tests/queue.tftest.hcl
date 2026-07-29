mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  prefix = "acme-prod"
  name   = "jobs"
}

run "naming_standard" {
  command = plan

  assert {
    condition     = output.name == "acme-prod-jobs"
    error_message = "The final name must be <prefix>-<name>."
  }

  assert {
    condition     = output.dlq_name == "acme-prod-jobs-dlq"
    error_message = "The DLQ must be named like the queue with a -dlq suffix."
  }
}

run "naming_fifo" {
  command = plan

  variables {
    fifo = { enabled = true }
  }

  # AWS requires a FIFO queue to have the .fifo suffix and its DLQ to be FIFO too:
  # the module composes it, so it is not a detail to remember.
  assert {
    condition     = output.name == "acme-prod-jobs.fifo"
    error_message = "A FIFO queue must have the .fifo suffix."
  }

  assert {
    condition     = output.dlq_name == "acme-prod-jobs-dlq.fifo"
    error_message = "The DLQ of a FIFO queue must be FIFO, with .fifo after -dlq."
  }
}

run "dlq_enabled_by_default" {
  command = plan

  # Without a DLQ a message that fails repeatedly stays in the queue until it expires
  # and then disappears, with nobody noticing.
  #
  # The assertion is on the name and not on the ARN: AWS assigns the ARN and it is not
  # known at plan time, while the name comes from the configuration.
  assert {
    condition     = output.dlq_name == "acme-prod-jobs-dlq"
    error_message = "The DLQ must be enabled by default."
  }

  assert {
    condition     = length(output.alarm_arns) == 2
    error_message = "With the DLQ enabled there must be two alarms: message age and non-empty DLQ."
  }
}

run "dlq_can_be_disabled" {
  command = plan

  variables {
    dlq = { enabled = false }
  }

  assert {
    condition     = output.dlq_arn == null
    error_message = "With dlq.enabled = false no DLQ must exist."
  }

  assert {
    condition     = output.dlq_name == null && output.dlq_url == null
    error_message = "The DLQ outputs must be null when the DLQ is disabled."
  }

  assert {
    condition     = length(output.alarm_arns) == 1
    error_message = "Without a DLQ only the message age alarm must remain."
  }
}

run "fan_in_from_several_topics_into_a_single_document" {
  command = plan

  variables {
    subscriptions = {
      operations = { topic_arn = "arn:aws:sns:eu-west-1:111122223333:acme-prod-operations" }
      audit      = { topic_arn = "arn:aws:sns:eu-west-1:111122223333:acme-prod-audit" }
      billing    = { topic_arn = "arn:aws:sns:eu-west-1:111122223333:acme-prod-billing" }
    }
  }

  # This is the regression the previous wiring had to fix by hand: SQS allows a single
  # Policy attribute per queue, so three topics must produce three statements in a
  # single document, not three policies overwriting each other.
  assert {
    condition     = output.policy_statement_sids == tolist(["SnsFromAudit", "SnsFromBilling", "SnsFromOperations"])
    error_message = "Three subscriptions must produce three distinct statements in a single document."
  }
}

run "service_sources_beyond_the_topics" {
  command = plan

  variables {
    subscriptions = {
      operations = { topic_arn = "arn:aws:sns:eu-west-1:111122223333:acme-prod-operations" }
    }
    allow_send_from = [
      { service = "s3", source_arn = "arn:aws:s3:::acme-prod-documents" },
      { service = "events", source_account = "111122223333" },
    ]
  }

  assert {
    condition     = output.policy_statement_sids == tolist(["EventsFrom1", "S3From0", "SnsFromOperations"])
    error_message = "Topics and service sources must converge into the same policy document."
  }
}

run "additional_statements" {
  command = plan

  variables {
    extra_policy_statements = {
      CrossAccountProducer = {
        actions    = ["sqs:SendMessage"]
        principals = [{ type = "AWS", identifiers = ["arn:aws:iam::999988887777:root"] }]
      }
    }
  }

  assert {
    condition     = output.policy_statement_sids == tolist(["CrossAccountProducer"])
    error_message = "The additional statements must go into the same document."
  }
}

run "no_policy_without_sources" {
  command = plan

  assert {
    condition     = length(output.policy_statement_sids) == 0
    error_message = "With no declared sources no policy must be generated."
  }
}

run "registry_entry_ready_for_the_consumers" {
  command = plan

  variables {
    encryption = { kms_key_id = "arn:aws:kms:eu-west-1:111122223333:key/abcd-1234" }
  }

  # Passing the CMK in the registry entry makes the consumers' KMS permissions be
  # generated from the grants. Forgetting it produces an AccessDenied on KMS at runtime
  # while the policy on SQS is perfect.
  assert {
    condition     = output.registry_entry.kms_key_arn == "arn:aws:kms:eu-west-1:111122223333:key/abcd-1234"
    error_message = "The registry entry must carry the queue's CMK."
  }

  assert {
    condition     = output.registry_entry.name == "acme-prod-jobs"
    error_message = "The registry entry must contain the queue's name, ARN and URL."
  }
}

run "alarms_can_be_disabled" {
  command = plan

  variables {
    alarms = { enabled = false }
  }

  assert {
    condition     = length(output.alarm_arns) == 0
    error_message = "alarms.enabled = false must create no alarm."
  }
}

run "dlq_threshold_at_one_message" {
  command = plan

  # Any message in a DLQ is an incident, not a metric to keep an eye on.
  assert {
    condition     = aws_cloudwatch_metric_alarm.dlq[0].threshold == 1
    error_message = "The DLQ alarm's threshold must be one message."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.dlq[0].dimensions["QueueName"] == "acme-prod-jobs-dlq"
    error_message = "The DLQ alarm must point at the DLQ, not at the main queue."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.age[0].dimensions["QueueName"] == "acme-prod-jobs"
    error_message = "The age alarm must point at the main queue."
  }
}
