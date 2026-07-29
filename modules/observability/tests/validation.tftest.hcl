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

run "no_topic_neither_created_nor_existing" {
  command = plan

  variables {
    alarm_topic = { create = false }
  }

  # Without a topic the other modules' alarms would have nowhere to be delivered.
  expect_failures = [output.alarm_topic_arn]
}

run "created_and_existing_topic_together" {
  command = plan

  variables {
    alarm_topic              = { create = true }
    existing_alarm_topic_arn = "arn:aws:sns:eu-west-1:111122223333:shared-alarms"
  }

  expect_failures = [output.alarm_topic_arn]
}

run "forwarding_without_a_log_group" {
  command = plan

  variables {
    log_shipping = {
      destination_arn = "arn:aws:firehose:eu-west-1:111122223333:deliverystream/loki"
      log_groups      = []
    }
  }

  expect_failures = [var.log_shipping]
}

run "composite_alarm_with_a_single_alarm" {
  command = plan

  variables {
    composite_alarm = {
      enabled    = true
      alarm_arns = ["arn:aws:cloudwatch:eu-west-1:111122223333:alarm:acme-prod-api-errors"]
    }
  }

  # With a single alarm it adds a layer of indirection without reducing anything.
  expect_failures = [var.composite_alarm]
}
