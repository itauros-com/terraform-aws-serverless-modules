data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  schedule_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.schedule_name })

  role_base = format("%s-scheduler", local.schedule_name)

  # IAM role names stop at 64 characters, and a schedule's name is the one most likely to
  # run past it: `<project>-<environment>-<what it does>` plus the `-scheduler` suffix
  # reaches 66 on a name as ordinary as `accessi-process-expirations-daily`. Left alone,
  # the provider rejects it at **apply**, after the plan has been reviewed and approved.
  #
  # So it is shortened deterministically: 55 characters of the name, then 8 hex of the
  # full name's SHA-1. Plain truncation would collide between two schedules sharing a long
  # prefix — which is exactly what a `<project>-<environment>-` convention produces — and
  # the collision would surface as an EntityAlreadyExists on whichever applied second.
  role_name = var.role_name != null ? var.role_name : (
    length(local.role_base) <= 64 ? local.role_base : format(
      "%s-%s", substr(local.role_base, 0, 55), substr(sha1(local.role_base), 0, 8)
    )
  )

  # The declared type wins over the inferred one: inferring it from a computed ARN makes
  # it unknown at plan time, and with it the only permission granted to the role.
  target_type = var.target.type != null ? var.target.type : (
    var.target.function_arn != null ? "lambda" :
    var.target.queue_arn != null ? "sqs" :
    var.target.glue_job_name != null ? "glue" :
    "sfn"
  )

  # A Glue job is declared by name, which is what StartJobRun takes, and its ARN — the one
  # the role's permission is scoped to — is derived from it. The format is fixed and the
  # region and account are this provider's, so the computation is exact.
  glue_job_arn = var.target.glue_job_name == null ? null : format(
    "arn:%s:glue:%s:%s:job/%s",
    data.aws_partition.current.partition,
    data.aws_region.current.region,
    data.aws_caller_identity.current.account_id,
    var.target.glue_job_name,
  )

  # The resource the role acts on.
  target_arn = coalesce(var.target.function_arn, var.target.queue_arn, var.target.state_machine_arn, local.glue_job_arn)

  # What Scheduler calls. Glue is not a templated target: it is reached through the
  # universal one, which calls the API action named in the ARN with the input as the
  # request body.
  invocation_arn = local.target_type == "glue" ? format(
    "arn:%s:scheduler:::aws-sdk:glue:startJobRun", data.aws_partition.current.partition
  ) : local.target_arn

  invocation_input = local.target_type == "glue" ? jsonencode(merge(
    { JobName = var.target.glue_job_name },
    var.target.arguments == null ? {} : { Arguments = var.target.arguments },
  )) : var.target.input

  # One action per target type, not a generic permission: this schedule's role can only
  # do the one thing it exists for.
  target_actions = {
    lambda = ["lambda:InvokeFunction"]
    sqs    = ["sqs:SendMessage"]
    sfn    = ["states:StartExecution"]
    glue   = ["glue:StartJobRun"]
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
  name               = local.role_name
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
    arn      = local.invocation_arn
    role_arn = aws_iam_role.this.arn
    input    = local.invocation_input

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
