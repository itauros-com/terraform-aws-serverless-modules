locals {
  alarms = var.observability.alarms

  # EventBridge rule names stop at 64 characters: shortened like the role's.
  rule_base = format("%s-failed", local.job_name)
  rule_name = length(local.rule_base) <= 64 ? local.rule_base : format(
    "%s-%s", substr(local.rule_base, 0, 55), substr(sha1(local.rule_base), 0, 8)
  )
}

# A failed run is an event, not a metric that stays in alarm: the run ends and nothing is
# left in ALARM state to look at. So the notification is an EventBridge rule on the job's
# state changes, not a CloudWatch alarm.
#
# Without it a job started by a function fails where nobody is looking: the function got
# its JobRunId back and returned, and the failure is in a console tab nobody opens.
resource "aws_cloudwatch_event_rule" "failed" {
  count = local.alarms.enabled ? 1 : 0

  name        = local.rule_name
  description = format("Runs of Glue job %s ending in %s.", local.job_name, join(", ", local.alarms.states))
  tags        = local.tags

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Job State Change"]
    detail = {
      jobName = [local.job_name]
      state   = local.alarms.states
    }
  })
}

# `count` and not `for_each`: the actions are ARNs of topics that may not exist yet, and
# a `for_each` over unknown values fails the plan. Their number is known.
resource "aws_cloudwatch_event_target" "failed" {
  count = local.alarms.enabled ? length(local.alarms.actions) : 0

  rule = aws_cloudwatch_event_rule.failed[0].name
  arn  = local.alarms.actions[count.index]

  # A sentence rather than the raw event: it reaches a mailbox or a chat through the
  # alarm topic, where a JSON document is read by nobody.
  input_transformer {
    input_paths = {
      job     = "$.detail.jobName"
      run     = "$.detail.jobRunId"
      state   = "$.detail.state"
      message = "$.detail.message"
    }
    input_template = "\"Glue job <job>, run <run>: <state>. <message>\""
  }
}
