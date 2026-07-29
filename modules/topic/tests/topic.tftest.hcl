mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  prefix = "acme-prod"
  name   = "operations"
}

run "naming_standard" {
  command = plan

  assert {
    condition     = output.name == "acme-prod-operations"
    error_message = "The final name must be <prefix>-<name>."
  }
}

run "naming_fifo" {
  command = plan

  variables {
    fifo = { enabled = true }
  }

  assert {
    condition     = output.name == "acme-prod-operations.fifo"
    error_message = "A FIFO topic must have the .fifo suffix."
  }
}

run "no_policy_without_service_publishers" {
  command = plan

  # Without a policy AWS's default applies: only the account owner publishes. Creating
  # a policy that says nothing is noise.
  assert {
    condition     = length(output.policy_statement_sids) == 0
    error_message = "Without service publishers no policy must be created."
  }
}

run "service_publishers_with_a_cmk" {
  command = plan

  variables {
    encryption = { kms_key_id = "arn:aws:kms:eu-west-1:111122223333:key/abcd-1234" }
    allow_publish_from = [
      { service = "s3", source_arn = "arn:aws:s3:::acme-prod-documents" },
      { service = "events", source_account = "111122223333" },
    ]
  }

  assert {
    condition     = output.policy_statement_sids == tolist(["EventsPublish1", "S3Publish0"])
    error_message = "Every service publisher must produce one statement in the topic's policy."
  }

  assert {
    condition     = output.registry_entry.kms_key_arn == "arn:aws:kms:eu-west-1:111122223333:key/abcd-1234"
    error_message = "The registry entry must carry the topic's CMK."
  }
}

run "non_sqs_subscriptions" {
  command = plan

  variables {
    subscriptions = {
      processor = { protocol = "lambda", endpoint = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-processor" }
      oncall    = { protocol = "email", endpoint = "oncall@acme.example" }
    }
  }

  assert {
    condition     = length(output.subscription_arns) == 2
    error_message = "Subscriptions towards non-SQS destinations must be created by the topic module."
  }
}

run "alarm_enabled_by_default" {
  command = plan

  # SNS retries and then discards the message without informing the publisher: without
  # this alarm the loss is invisible.
  assert {
    condition     = length(output.alarm_arns) == 1
    error_message = "The alarm on failed notifications must be enabled by default."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.failed[0].threshold == 1
    error_message = "The threshold must be one failed notification."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.failed[0].dimensions["TopicName"] == "acme-prod-operations"
    error_message = "The alarm must point at the topic by name."
  }
}

run "alarm_can_be_disabled" {
  command = plan

  variables {
    alarms = { enabled = false }
  }

  assert {
    condition     = length(output.alarm_arns) == 0
    error_message = "alarms.enabled = false must create no alarm."
  }
}
