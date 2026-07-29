mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      name   = "eu-west-1"
      region = "eu-west-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
      arn        = "arn:aws:iam::111122223333:root"
      id         = "111122223333"
      user_id    = "111122223333"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  prefix = "acme-prod"
  name   = "app"
}

run "an_empty_dashboard_is_not_created" {
  command = plan

  # A dashboard with no widgets takes up one of the account's three free ones without
  # showing anything.
  assert {
    condition     = output.dashboard_widget_count == 0
    error_message = "With no declared resources there must be no widgets."
  }

  assert {
    condition     = output.dashboard_name == null
    error_message = "Without widgets the dashboard must not be created."
  }
}

run "dashboard_with_every_resource" {
  command = plan

  variables {
    functions = ["acme-prod-api", "acme-prod-worker"]
    queues    = ["acme-prod-jobs", "acme-prod-jobs-dlq"]
    tables    = ["acme-prod-tenants"]
    apis      = [{ id = "abc123", stage = "$default" }]
  }

  # Two widgets per resource type, four types.
  assert {
    condition     = output.dashboard_widget_count == 8
    error_message = "Every declared resource type must produce two widgets."
  }

  assert {
    condition     = output.dashboard_name == "acme-prod-app"
    error_message = "The dashboard must take its name from the application."
  }

  # In two columns: the third widget goes back to x = 0 and drops to y = 6.
  assert {
    condition     = local.positioned_widgets[0].x == 0 && local.positioned_widgets[1].x == 12
    error_message = "The widgets must be laid out in two columns."
  }

  assert {
    condition     = local.positioned_widgets[2].y == 6
    error_message = "The third widget must start a new row."
  }
}

run "api_metrics_with_the_correct_name" {
  command = plan

  variables {
    apis = [{ id = "abc123" }]
  }

  # On HTTP APIs the metric is `5xx`. `5XXError` belongs to the REST APIs and would produce
  # a chart that is always empty.
  assert {
    condition = contains(
      [for m in local.api_widgets[0].properties.metrics : m[1]],
      "5xx"
    )
    error_message = "The API widget must use the HTTP APIs' '5xx' metric."
  }
}

run "alarm_topic_without_encryption_by_default" {
  command = plan

  # CloudWatch cannot use the AWS-managed key: with `alias/aws/sns` the alarms would not
  # arrive, and the failure is silent because an alarm that fails to notify does not itself
  # raise an alarm.
  assert {
    condition     = module.alarm_topic[0].registry_entry.kms_key_arn == null
    error_message = "The alarm topic must not use the AWS-managed key."
  }
}

run "existing_topic" {
  command = plan

  variables {
    alarm_topic              = { create = false }
    existing_alarm_topic_arn = "arn:aws:sns:eu-west-1:111122223333:shared-alarms"
  }

  assert {
    condition     = output.alarm_topic_arn == "arn:aws:sns:eu-west-1:111122223333:shared-alarms"
    error_message = "With an existing topic the module must not create a new one."
  }

  assert {
    condition     = length(module.alarm_topic) == 0
    error_message = "With an existing topic no topic must be created."
  }
}

run "log_forwarding" {
  command = plan

  variables {
    log_shipping = {
      destination_arn = "arn:aws:firehose:eu-west-1:111122223333:deliverystream/loki"
      role_arn        = "arn:aws:iam::111122223333:role/acme-prod-log-shipping"
      filter_pattern  = "{ $.level = \"error\" }"
      log_groups      = ["/aws/lambda/acme-prod-api", "/aws/lambda/acme-prod-worker"]
    }
  }

  assert {
    condition     = length(aws_cloudwatch_log_subscription_filter.this) == 2
    error_message = "One subscription filter per log group must be created."
  }

  assert {
    condition     = output.shipped_log_groups == tolist(["/aws/lambda/acme-prod-api", "/aws/lambda/acme-prod-worker"])
    error_message = "The forwarded log groups must appear in the outputs, sorted."
  }
}

run "composite_alarm" {
  command = plan

  variables {
    composite_alarm = {
      enabled = true
      alarm_arns = [
        "arn:aws:cloudwatch:eu-west-1:111122223333:alarm:acme-prod-api-errors",
        "arn:aws:cloudwatch:eu-west-1:111122223333:alarm:acme-prod-jobs-dlq-not-empty",
      ]
    }
  }

  # It cuts the noise: an incident lighting up six alarms notifies once.
  assert {
    condition     = aws_cloudwatch_composite_alarm.this[0].alarm_rule == "ALARM(arn:aws:cloudwatch:eu-west-1:111122223333:alarm:acme-prod-api-errors) OR ALARM(arn:aws:cloudwatch:eu-west-1:111122223333:alarm:acme-prod-jobs-dlq-not-empty)"
    error_message = "The composite alarm's rule must be the disjunction of the listed alarms."
  }
}

run "no_composite_alarm_by_default" {
  command = plan

  assert {
    condition     = output.composite_alarm_arn == null
    error_message = "The composite alarm must be disabled by default."
  }
}
