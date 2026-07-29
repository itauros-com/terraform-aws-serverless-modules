# schedule

An **EventBridge Scheduler** schedule with its role, retry policy and DLQ.

## Usage

```hcl
module "cleanup" {
  source = "…//modules/schedule"

  prefix     = "acme-prod"
  name       = "cleanup"
  expression = "cron(0 3 * * ? *)"
  timezone   = "Europe/Rome"

  target = {
    function_arn = module.cleanup.arn
    input        = jsonencode({ job = "cleanup" })
  }

  # Without it, a failed invocation disappears without a trace.
  dead_letter_arn = module.jobs.dlq_arn
}
```

## Scheduler, not EventBridge rules

`aws_scheduler_schedule` and not `aws_cloudwatch_event_rule`. Rules remain valid for events, but for
scheduling Scheduler offers native time zones, flexibility windows, retry policies and a DLQ per target —
things that with rules have to be built by hand or do not exist.

## The role takes its name from the schedule

In the previous wiring the IAM role was named after the **bus** it belonged to. Two groups of schedules on
the same bus therefore tried to create two roles with the same name, and the second apply failed — a
problem solved there by adding a name override on every instance after the first.

Here the role is per-schedule and takes its name from the schedule: the collision is no longer possible,
instead of being possible and avoided by hand.

The role receives **a single action**, the one matching the target type:

| target | action |
|---|---|
| `function_arn` | `lambda:InvokeFunction` |
| `queue_arn` | `sqs:SendMessage` |
| `state_machine_arn` | `states:StartExecution` |

With a `dead_letter_arn`, `sqs:SendMessage` on that queue is added. Without that permission the DLQ is
configured but Scheduler cannot write to it: the failed events are lost all the same, and the configuration
looks correct.

## The DLQ is mandatory unless declared otherwise

A scheduled invocation that fails after the expected attempts **disappears**. There is no log, no metric
telling which execution was missed, and the first signal is that the work was not done — usually discovered
much later.

The module stops the plan if `dead_letter_arn` is absent. For idempotent schedules, where the next execution
makes up for it on its own, you declare `allow_missing_dead_letter = true`: it is a choice, not an omission.

## Notes

- Scheduler's cron has **six fields** and requires `?` in one of day-of-month and day-of-week. A five-field
  expression copied from crontab is rejected.
- `timezone` with a zone that observes daylight saving time makes the schedule change its time twice a year.
  If that matters, use `UTC` and handle the conversion elsewhere.
- `flexible_time_window_minutes` spreads the load: many schedules starting on the same minute produce a
  concurrency spike at minute zero, which is the typical way to get all the invocations throttled together.
- Scheduler schedules do not support tags: the `tags` passed to the module end up on the IAM role.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.target](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_scheduler_schedule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [aws_iam_policy_document.assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.target](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_expression"></a> [expression](#input\_expression) | Scheduling expression: `rate(1 hour)`, `cron(0 8 * * ? *)` or<br/>`at(2026-12-31T23:00:00)`.<br/><br/>Note that Scheduler's cron format has **six fields** and requires the `?` character in<br/>one of day-of-month and day-of-week: a five-field cron expression copied from crontab<br/>is rejected. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | The schedule's name. If `prefix` is set the final name is `<prefix>-<name>`. | `string` | n/a | yes |
| <a name="input_target"></a> [target](#input\_target) | The invocation's destination. State **exactly one** of `function_arn`, `queue_arn` and<br/>`state_machine_arn`: the module generates the IAM permission matching the type, so the<br/>type is declared and not inferred.<br/><br/>    target = {<br/>      function\_arn = module.cleanup.arn<br/>      input        = jsonencode({ job = "cleanup" })<br/>    } | <pre>object({<br/>    function_arn      = optional(string)<br/>    queue_arn         = optional(string)<br/>    state_machine_arn = optional(string)<br/>    input             = optional(string)<br/>    message_group_id  = optional(string)<br/><br/>    # Redundant with respect to which ARN is set, but not superfluous: the ARNs come from<br/>    # resources not yet created and are unknown at plan time, so inferring the type from<br/>    # them makes the only permission granted to the role unknown too. With the type<br/>    # declared the policy is readable in the plan.<br/>    type = optional(string)<br/>  })</pre> | n/a | yes |
| <a name="input_allow_missing_dead_letter"></a> [allow\_missing\_dead\_letter](#input\_allow\_missing\_dead\_letter) | Allows creating the schedule without `dead_letter_arn`.<br/><br/>It is for idempotent schedules that are re-run on the next cycle anyway, where a single<br/>lost invocation has no consequences. It is a choice to be declared, not a default. | `bool` | `false` | no |
| <a name="input_dead_letter_arn"></a> [dead\_letter\_arn](#input\_dead\_letter\_arn) | The SQS queue where invocations that did not succeed after the expected attempts end<br/>up.<br/><br/>Without it, a scheduled invocation that fails **disappears without a trace**: there is<br/>no log, no metric telling which execution was missed, and the first signal is that the<br/>work was not done. The module reports it if it is missing. | `string` | `null` | no |
| <a name="input_description"></a> [description](#input\_description) | The schedule's description. | `string` | `null` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | The schedule's state. `false` leaves it configured but does not run it. | `bool` | `true` | no |
| <a name="input_end_date"></a> [end\_date](#input\_end\_date) | End date in RFC3339 format. Null never expires. | `string` | `null` | no |
| <a name="input_flexible_time_window_minutes"></a> [flexible\_time\_window\_minutes](#input\_flexible\_time\_window\_minutes) | Flexibility window in minutes. Null runs at the exact time.<br/><br/>With many schedules starting on the same minute a window spreads the load and avoids<br/>the concurrency spike at minute zero, which is the typical way to get all the<br/>invocations throttled together. | `number` | `null` | no |
| <a name="input_group_name"></a> [group\_name](#input\_group\_name) | The schedule group to belong to. Null uses the `default` group. | `string` | `null` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, typically `<project>-<environment>`. | `string` | `null` | no |
| <a name="input_retry"></a> [retry](#input\_retry) | Retry policy. `maximum_event_age_in_seconds` limits how long Scheduler keeps retrying:<br/>beyond that window the event goes to the DLQ. | <pre>object({<br/>    maximum_retry_attempts       = optional(number, 3)<br/>    maximum_event_age_in_seconds = optional(number, 3600)<br/>  })</pre> | `{}` | no |
| <a name="input_start_date"></a> [start\_date](#input\_start\_date) | Start date in RFC3339 format. Null starts immediately. | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to the resources the module creates. EventBridge Scheduler schedules do not support tags: they are applied to the IAM role. | `map(string)` | `{}` | no |
| <a name="input_timezone"></a> [timezone](#input\_timezone) | Time zone for the cron expressions. `UTC` by default.<br/><br/>With a zone that observes daylight saving time a nightly schedule changes its time<br/>twice a year: if that matters, use UTC and make the conversion explicit elsewhere. | `string` | `"UTC"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_arn"></a> [arn](#output\_arn) | The schedule's ARN. |
| <a name="output_name"></a> [name](#output\_name) | The schedule's name, already prefixed. |
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | ARN of the role Scheduler assumes to invoke the target. |
| <a name="output_role_name"></a> [role\_name](#output\_role\_name) | The role's name. It derives from the schedule and not from the group, so two schedules in the same group do not collide. |
| <a name="output_target_arn"></a> [target\_arn](#output\_target\_arn) | The target's ARN. |
| <a name="output_target_type"></a> [target\_type](#output\_target\_type) | The detected target type: `lambda`, `sqs` or `sfn`. It determines the only action granted to the role. |
<!-- END_TF_DOCS -->
