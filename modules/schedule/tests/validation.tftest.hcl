mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  prefix          = "acme-prod"
  name            = "cleanup"
  expression      = "cron(0 3 * * ? *)"
  dead_letter_arn = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-schedule-dlq"

  target = {
    function_arn = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-cleanup"
  }
}

run "without_a_dlq_and_without_declaring_it" {
  command = plan

  variables {
    dead_letter_arn = null
  }

  # A scheduled invocation that fails without a DLQ disappears: there is no log and no
  # metric telling which execution was missed.
  expect_failures = [output.arn]
}

run "unrecognized_expression" {
  command = plan

  variables {
    expression = "0 3 * * *"
  }

  # A five-field crontab expression is not a Scheduler expression.
  expect_failures = [var.expression]
}

run "no_target" {
  command = plan

  variables {
    target = {}
  }

  expect_failures = [var.target]
}

run "two_targets" {
  command = plan

  variables {
    target = {
      function_arn = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-cleanup"
      queue_arn    = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-jobs"
    }
  }

  expect_failures = [var.target]
}

run "message_group_id_on_a_non_sqs_target" {
  command = plan

  variables {
    target = {
      function_arn     = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-cleanup"
      message_group_id = "cleanup"
    }
  }

  expect_failures = [var.target]
}

run "too_many_attempts" {
  command = plan

  variables {
    retry = { maximum_retry_attempts = 200 }
  }

  expect_failures = [var.retry]
}

run "window_out_of_range" {
  command = plan

  variables {
    flexible_time_window_minutes = 2000
  }

  expect_failures = [var.flexible_time_window_minutes]
}
