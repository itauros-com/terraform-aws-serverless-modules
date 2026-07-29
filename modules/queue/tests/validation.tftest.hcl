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

run "fifo_suffix_in_the_name" {
  command = plan

  variables {
    name = "jobs.fifo"
    fifo = { enabled = true }
  }

  # If the caller added `.fifo` by hand the module would produce `jobs.fifo.fifo`:
  # better to reject it.
  expect_failures = [var.name]
}

run "source_without_a_condition" {
  command = plan

  variables {
    allow_send_from = [
      { service = "s3" }
    ]
  }

  # Without source_arn or source_account the policy would authorize any bucket in any
  # account to write to the queue.
  expect_failures = [var.allow_send_from]
}

run "source_with_two_conditions" {
  command = plan

  variables {
    allow_send_from = [
      { service = "s3", source_arn = "arn:aws:s3:::acme", source_account = "111122223333" }
    ]
  }

  expect_failures = [var.allow_send_from]
}

run "service_with_the_full_suffix" {
  command = plan

  variables {
    allow_send_from = [
      { service = "s3.amazonaws.com", source_arn = "arn:aws:s3:::acme" }
    ]
  }

  # The module adds `.amazonaws.com`: passing it would produce
  # `s3.amazonaws.com.amazonaws.com`.
  expect_failures = [var.allow_send_from]
}

run "non_alphanumeric_subscription_key" {
  command = plan

  variables {
    subscriptions = {
      "operations/critical" = { topic_arn = "arn:aws:sns:eu-west-1:111122223333:acme-prod-operations" }
    }
  }

  # The keys become policy Sids, which only accept alphanumeric characters.
  expect_failures = [var.subscriptions]
}

run "invalid_filter_policy_scope" {
  command = plan

  variables {
    subscriptions = {
      operations = {
        topic_arn           = "arn:aws:sns:eu-west-1:111122223333:acme-prod-operations"
        filter_policy       = "{}"
        filter_policy_scope = "Body"
      }
    }
  }

  expect_failures = [var.subscriptions]
}

run "max_receive_count_out_of_range" {
  command = plan

  variables {
    dlq = { max_receive_count = 0 }
  }

  expect_failures = [var.dlq]
}

run "long_polling_beyond_the_maximum" {
  command = plan

  variables {
    receive_wait_time_seconds = 30
  }

  expect_failures = [var.receive_wait_time_seconds]
}

run "visibility_timeout_out_of_range" {
  command = plan

  variables {
    visibility_timeout_seconds = 50000
  }

  expect_failures = [var.visibility_timeout_seconds]
}

run "retention_out_of_range" {
  command = plan

  variables {
    message_retention_seconds = 30
  }

  expect_failures = [var.message_retention_seconds]
}

run "invalid_deduplication_scope" {
  command = plan

  variables {
    fifo = { enabled = true, deduplication_scope = "message" }
  }

  expect_failures = [var.fifo]
}
