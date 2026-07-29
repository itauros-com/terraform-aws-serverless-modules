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
    input        = "{\"job\":\"cleanup\"}"
  }
}

run "target_lambda" {
  command = plan

  assert {
    condition     = output.target_type == "lambda"
    error_message = "The target type must be detected from which ARN is set."
  }

  assert {
    condition     = output.name == "acme-prod-cleanup"
    error_message = "The final name must be <prefix>-<name>."
  }
}

run "role_derived_from_the_schedule_not_from_the_group" {
  command = plan

  variables {
    group_name = "maintenance"
  }

  # In the previous wiring the role took its name from the bus: two groups of schedules on
  # the same bus created two namesake roles and the second apply failed. Tying it to the
  # schedule makes the collision impossible.
  assert {
    condition     = output.role_name == "acme-prod-cleanup-scheduler"
    error_message = "The role's name must derive from the schedule, not from the group."
  }
}

run "target_sqs" {
  command = plan

  variables {
    target = {
      queue_arn        = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-jobs.fifo"
      message_group_id = "cleanup"
    }
  }

  assert {
    condition     = output.target_type == "sqs"
    error_message = "With queue_arn the type must be sqs."
  }
}

run "target_state_machine" {
  command = plan

  variables {
    target = {
      state_machine_arn = "arn:aws:states:eu-west-1:111122223333:stateMachine:acme-prod-pipeline"
    }
  }

  assert {
    condition     = output.target_type == "sfn"
    error_message = "With state_machine_arn the type must be sfn."
  }
}

run "exact_time_by_default" {
  command = plan

  assert {
    condition     = one(aws_scheduler_schedule.this.flexible_time_window).mode == "OFF"
    error_message = "By default the schedule must run at the exact time."
  }
}

run "flexible_window" {
  command = plan

  variables {
    flexible_time_window_minutes = 15
  }

  # With many schedules on the same minute the window spreads the load and avoids the
  # concurrency spike at minute zero.
  assert {
    condition     = one(aws_scheduler_schedule.this.flexible_time_window).mode == "FLEXIBLE"
    error_message = "With a declared window the mode must be FLEXIBLE."
  }

  assert {
    condition     = one(aws_scheduler_schedule.this.flexible_time_window).maximum_window_in_minutes == 15
    error_message = "The window must be the configured one."
  }
}

run "disabled_schedule" {
  command = plan

  variables {
    enabled = false
  }

  assert {
    condition     = aws_scheduler_schedule.this.state == "DISABLED"
    error_message = "enabled = false must leave the schedule configured but not active."
  }
}

run "idempotent_schedule_without_a_dlq" {
  command = plan

  variables {
    dead_letter_arn           = null
    allow_missing_dead_letter = true
  }

  assert {
    condition     = output.target_type == "lambda"
    error_message = "An idempotent schedule must be able to exist without a DLQ, by declaring it."
  }
}
