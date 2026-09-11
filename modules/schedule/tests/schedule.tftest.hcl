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

# `<prefix>-<name>-scheduler` reaches 66 characters on a name as ordinary as
# `accessi-process-expirations-daily`. Left alone the provider rejects it at apply, after
# the plan has been reviewed — which is the worst moment to find out.
run "long_role_name_is_shortened_to_fit_iam" {
  command = plan

  variables {
    prefix = "powerflow-smartflow-dev"
    name   = "accessi-process-expirations-daily"
  }

  assert {
    condition     = length(local.role_name) <= 64
    error_message = "An IAM role name stops at 64 characters."
  }

  # Plain truncation would collide between two schedules sharing a long prefix, and the
  # collision surfaces as an EntityAlreadyExists on whichever applies second.
  assert {
    condition     = endswith(local.role_name, substr(sha1(local.role_base), 0, 8))
    error_message = "A shortened name must carry the hash that keeps it unique."
  }

  assert {
    condition     = startswith(local.role_name, "powerflow-smartflow-dev-accessi-process-")
    error_message = "A shortened name must stay recognisable."
  }
}

run "short_role_name_is_left_alone" {
  command = plan

  variables {
    prefix = "acme-prod"
    name   = "cleanup"
  }

  assert {
    condition     = local.role_name == "acme-prod-cleanup-scheduler"
    error_message = "A name that fits must not be touched."
  }
}

run "role_name_can_be_chosen" {
  command = plan

  variables {
    prefix    = "powerflow-smartflow-dev"
    name      = "accessi-process-expirations-daily"
    role_name = "powerflow-dev-expirations-scheduler"
  }

  assert {
    condition     = local.role_name == "powerflow-dev-expirations-scheduler"
    error_message = "An explicit name must win over the derived one."
  }
}
