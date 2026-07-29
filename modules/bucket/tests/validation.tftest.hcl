mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  prefix = "acme-prod"
  name   = "documents"
}

run "notification_without_events" {
  command = plan

  variables {
    notifications = {
      queues = {
        ingest = { queue_arn = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-ingest", events = [] }
      }
    }
  }

  expect_failures = [var.notifications]
}

run "non_s3_event" {
  command = plan

  variables {
    notifications = {
      queues = {
        ingest = { queue_arn = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-ingest", events = ["ObjectCreated:*"] }
      }
    }
  }

  expect_failures = [var.notifications]
}

run "cors_with_an_unsupported_method" {
  command = plan

  variables {
    cors_rules = [
      { allowed_methods = ["PATCH"], allowed_origins = ["https://app.acme.example"] }
    ]
  }

  expect_failures = [var.cors_rules]
}

run "cors_with_a_wildcard_and_explicit_origins" {
  command = plan

  variables {
    cors_rules = [
      { allowed_methods = ["GET"], allowed_origins = ["*", "https://app.acme.example"] }
    ]
  }

  # A '*' makes the other listed origins pointless: the list gives the impression of
  # restricting something that is in fact open to everyone.
  expect_failures = [var.cors_rules]
}

run "invalid_object_ownership" {
  command = plan

  variables {
    object_ownership = "BucketOwner"
  }

  expect_failures = [var.object_ownership]
}
