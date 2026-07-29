locals {
  schedule_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.schedule_name })

  # The declared type wins over the inferred one: inferring it from a computed ARN makes
  # it unknown at plan time, and with it the only permission granted to the role.
  target_type = var.target.type != null ? var.target.type : (
    var.target.function_arn != null ? "lambda" :
    var.target.queue_arn != null ? "sqs" :
    "sfn"
  )

  target_arn = coalesce(var.target.function_arn, var.target.queue_arn, var.target.state_machine_arn)

  # One action per target type, not a generic permission: this schedule's role can only
  # do the one thing it exists for.
  target_actions = {
    lambda = ["lambda:InvokeFunction"]
    sqs    = ["sqs:SendMessage"]
    sfn    = ["states:StartExecution"]
  }

  needs_dead_letter_warning = var.dead_letter_arn == null && !var.allow_missing_dead_letter
}

# The role is per-schedule and takes its name from the schedule.
#
# In the previous wiring the role was named after the bus it belonged to, so two groups of
# schedules on the same bus tried to create two roles with the same name and the second
# apply failed. Tying it to the schedule eliminates the whole class of problem instead of
# requiring an override for every instance after the first.
data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = format("%s-scheduler", local.schedule_name)
  description        = format("EventBridge Scheduler role for %s", local.schedule_name)
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "target" {
  statement {
    sid       = "InvokeTarget"
    effect    = "Allow"
    actions   = local.target_actions[local.target_type]
    resources = [local.target_arn]
  }

  # Without this permission the DLQ is configured but Scheduler cannot write to it: the
  # failed events are lost all the same, and the configuration looks correct.
  dynamic "statement" {
    for_each = var.dead_letter_arn == null ? [] : [var.dead_letter_arn]

    content {
      sid       = "WriteToDeadLetterQueue"
      effect    = "Allow"
      actions   = ["sqs:SendMessage"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role_policy" "target" {
  name   = format("%s-target", local.schedule_name)
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.target.json
}

resource "aws_scheduler_schedule" "this" {
  name        = local.schedule_name
  description = var.description
  group_name  = var.group_name
  state       = var.enabled ? "ENABLED" : "DISABLED"

  schedule_expression          = var.expression
  schedule_expression_timezone = var.timezone
  start_date                   = var.start_date
  end_date                     = var.end_date

  flexible_time_window {
    mode                      = var.flexible_time_window_minutes == null ? "OFF" : "FLEXIBLE"
    maximum_window_in_minutes = var.flexible_time_window_minutes
  }

  target {
    arn      = local.target_arn
    role_arn = aws_iam_role.this.arn
    input    = var.target.input

    retry_policy {
      maximum_retry_attempts       = var.retry.maximum_retry_attempts
      maximum_event_age_in_seconds = var.retry.maximum_event_age_in_seconds
    }

    dynamic "dead_letter_config" {
      for_each = var.dead_letter_arn == null ? [] : [var.dead_letter_arn]

      content {
        arn = dead_letter_config.value
      }
    }

    dynamic "sqs_parameters" {
      for_each = var.target.message_group_id == null ? [] : [var.target.message_group_id]

      content {
        message_group_id = sqs_parameters.value
      }
    }
  }
}
