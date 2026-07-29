output "arn" {
  description = "The schedule's ARN."
  value       = aws_scheduler_schedule.this.arn

  # A scheduled invocation that fails without a DLQ disappears: there is no log, no metric
  # telling which execution was missed, and the first signal is that the work was not
  # done.
  precondition {
    condition     = !local.needs_dead_letter_warning
    error_message = "This schedule has no `dead_letter_arn`: an invocation that exhausts its attempts is lost without a trace. Pass a queue's DLQ, or declare `allow_missing_dead_letter = true` if the schedule is idempotent and the next execution makes up for it on its own."
  }
}

output "name" {
  description = "The schedule's name, already prefixed."
  value       = aws_scheduler_schedule.this.name
}

output "role_arn" {
  description = "ARN of the role Scheduler assumes to invoke the target."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "The role's name. It derives from the schedule and not from the group, so two schedules in the same group do not collide."
  value       = aws_iam_role.this.name
}

output "target_type" {
  description = "The detected target type: `lambda`, `sqs` or `sfn`. It determines the only action granted to the role."
  value       = local.target_type
}

output "target_arn" {
  description = "The target's ARN."
  value       = local.target_arn
}
