variable "name" {
  description = "The schedule's name. If `prefix` is set the final name is `<prefix>-<name>`."
  type        = string
}

variable "prefix" {
  description = "Naming prefix, typically `<project>-<environment>`."
  type        = string
  default     = null
}

variable "description" {
  description = "The schedule's description."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the resources the module creates. EventBridge Scheduler schedules do not support tags: they are applied to the IAM role."
  type        = map(string)
  default     = {}
}

variable "enabled" {
  description = "The schedule's state. `false` leaves it configured but does not run it."
  type        = bool
  default     = true
}

variable "group_name" {
  description = "The schedule group to belong to. Null uses the `default` group."
  type        = string
  default     = null
}

variable "expression" {
  description = <<-EOT
    Scheduling expression: `rate(1 hour)`, `cron(0 8 * * ? *)` or
    `at(2026-12-31T23:00:00)`.

    Note that Scheduler's cron format has **six fields** and requires the `?` character in
    one of day-of-month and day-of-week: a five-field cron expression copied from crontab
    is rejected.
  EOT
  type        = string

  validation {
    condition     = can(regex("^(rate\\(|cron\\(|at\\()", var.expression))
    error_message = "expression must start with 'rate(', 'cron(' or 'at('."
  }
}

variable "timezone" {
  description = <<-EOT
    Time zone for the cron expressions. `UTC` by default.

    With a zone that observes daylight saving time a nightly schedule changes its time
    twice a year: if that matters, use UTC and make the conversion explicit elsewhere.
  EOT
  type        = string
  default     = "UTC"
}

variable "target" {
  description = <<-EOT
    The invocation's destination. State **exactly one** of `function_arn`, `queue_arn` and
    `state_machine_arn`: the module generates the IAM permission matching the type, so the
    type is declared and not inferred.

        target = {
          function_arn = module.cleanup.arn
          input        = jsonencode({ job = "cleanup" })
        }
  EOT
  type = object({
    function_arn      = optional(string)
    queue_arn         = optional(string)
    state_machine_arn = optional(string)
    input             = optional(string)
    message_group_id  = optional(string)

    # Redundant with respect to which ARN is set, but not superfluous: the ARNs come from
    # resources not yet created and are unknown at plan time, so inferring the type from
    # them makes the only permission granted to the role unknown too. With the type
    # declared the policy is readable in the plan.
    type = optional(string)
  })

  validation {
    condition = length([
      for v in [var.target.function_arn, var.target.queue_arn, var.target.state_machine_arn] : v if v != null
    ]) == 1
    error_message = "target must state exactly one of `function_arn`, `queue_arn` and `state_machine_arn`."
  }

  validation {
    condition     = var.target.message_group_id == null || var.target.queue_arn != null
    error_message = "message_group_id only applies to a FIFO queue: set `queue_arn`."
  }

  validation {
    condition     = var.target.type == null || contains(["lambda", "sqs", "sfn"], coalesce(var.target.type, "x"))
    error_message = "target.type must be 'lambda', 'sqs' or 'sfn'."
  }
}

variable "dead_letter_arn" {
  description = <<-EOT
    The SQS queue where invocations that did not succeed after the expected attempts end
    up.

    Without it, a scheduled invocation that fails **disappears without a trace**: there is
    no log, no metric telling which execution was missed, and the first signal is that the
    work was not done. The module reports it if it is missing.
  EOT
  type        = string
  default     = null
}

variable "allow_missing_dead_letter" {
  description = <<-EOT
    Allows creating the schedule without `dead_letter_arn`.

    It is for idempotent schedules that are re-run on the next cycle anyway, where a single
    lost invocation has no consequences. It is a choice to be declared, not a default.
  EOT
  type        = bool
  default     = false
}

variable "retry" {
  description = <<-EOT
    Retry policy. `maximum_event_age_in_seconds` limits how long Scheduler keeps retrying:
    beyond that window the event goes to the DLQ.
  EOT
  type = object({
    maximum_retry_attempts       = optional(number, 3)
    maximum_event_age_in_seconds = optional(number, 3600)
  })
  default = {}

  validation {
    condition     = var.retry.maximum_retry_attempts >= 0 && var.retry.maximum_retry_attempts <= 185
    error_message = "retry.maximum_retry_attempts must be between 0 and 185."
  }

  validation {
    condition     = var.retry.maximum_event_age_in_seconds >= 60 && var.retry.maximum_event_age_in_seconds <= 86400
    error_message = "retry.maximum_event_age_in_seconds must be between 60 and 86400."
  }
}

variable "flexible_time_window_minutes" {
  description = <<-EOT
    Flexibility window in minutes. Null runs at the exact time.

    With many schedules starting on the same minute a window spreads the load and avoids
    the concurrency spike at minute zero, which is the typical way to get all the
    invocations throttled together.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.flexible_time_window_minutes == null || (var.flexible_time_window_minutes >= 1 && var.flexible_time_window_minutes <= 1440)
    error_message = "flexible_time_window_minutes must be between 1 and 1440."
  }
}

variable "start_date" {
  description = "Start date in RFC3339 format. Null starts immediately."
  type        = string
  default     = null
}

variable "end_date" {
  description = "End date in RFC3339 format. Null never expires."
  type        = string
  default     = null
}
