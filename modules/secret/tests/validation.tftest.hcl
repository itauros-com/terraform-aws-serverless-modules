mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  prefix = "acme-prod"
  name   = "database"
}

run "recovery_window_too_short" {
  command = plan

  variables {
    recovery_window_in_days = 3
  }

  # AWS accepts 0 or a value between 7 and 30: 3 would be rejected by the API.
  expect_failures = [var.recovery_window_in_days]
}

run "rotation_without_a_lambda" {
  command = plan

  variables {
    rotation = { enabled = true, automatically_after_days = 30 }
  }

  expect_failures = [var.rotation]
}

run "rotation_with_two_schedules" {
  command = plan

  variables {
    rotation = {
      enabled                  = true
      lambda_arn               = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-rotator"
      automatically_after_days = 30
      schedule_expression      = "rate(30 days)"
    }
  }

  expect_failures = [var.rotation]
}

run "rotation_without_a_schedule" {
  command = plan

  variables {
    rotation = {
      enabled    = true
      lambda_arn = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-rotator"
    }
  }

  expect_failures = [var.rotation]
}
