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

run "sqs_subscription_rejected" {
  command = plan

  variables {
    subscriptions = {
      jobs = { protocol = "sqs", endpoint = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-jobs" }
    }
  }

  # The design's central guardrail: declaring an SQS subscription from the topic side
  # works with a single topic and breaks silently at the second one, because SQS allows
  # a single policy per queue.
  expect_failures = [var.subscriptions]
}

run "service_publisher_with_the_aws_managed_key" {
  command = plan

  variables {
    # `encryption` left at its default: the AWS-managed key.
    allow_publish_from = [
      { service = "s3", source_arn = "arn:aws:s3:::acme-prod-documents" },
    ]
  }

  # S3 cannot use alias/aws/sns: the publication would fail at runtime with a
  # KMSAccessDenied invisible in Terraform, and the message would be lost.
  expect_failures = [output.arn]
}

run "nonexistent_protocol" {
  command = plan

  variables {
    subscriptions = {
      something = { protocol = "webhook", endpoint = "https://acme.example/hook" }
    }
  }

  expect_failures = [var.subscriptions]
}

run "firehose_without_a_role" {
  command = plan

  variables {
    subscriptions = {
      analytics = { protocol = "firehose", endpoint = "arn:aws:firehose:eu-west-1:111122223333:deliverystream/acme" }
    }
  }

  expect_failures = [var.subscriptions]
}

run "fifo_suffix_in_the_name" {
  command = plan

  variables {
    name = "operations.fifo"
    fifo = { enabled = true }
  }

  expect_failures = [var.name]
}

run "publisher_without_a_condition" {
  command = plan

  variables {
    encryption         = { managed = false }
    allow_publish_from = [{ service = "s3" }]
  }

  expect_failures = [var.allow_publish_from]
}

run "publisher_with_the_full_suffix" {
  command = plan

  variables {
    encryption         = { managed = false }
    allow_publish_from = [{ service = "s3.amazonaws.com", source_arn = "arn:aws:s3:::acme" }]
  }

  expect_failures = [var.allow_publish_from]
}

run "invalid_throughput_scope" {
  command = plan

  variables {
    fifo = { enabled = true, throughput_scope = "Queue" }
  }

  expect_failures = [var.fifo]
}

run "invalid_tracing_config" {
  command = plan

  variables {
    tracing_config = "Enabled"
  }

  expect_failures = [var.tracing_config]
}
