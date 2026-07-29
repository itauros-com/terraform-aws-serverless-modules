# This test exists for a precise reason: `terraform validate` evaluates neither variable
# validations nor preconditions, so it does not see an example's wiring errors — a registry not
# passed to a module, a grant that does not match an event source. With a mocked provider the
# plan runs without credentials and catches them all.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

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

  mock_data "aws_iam_policy" {
    defaults = {
      arn    = "arn:aws:iam::aws:policy/service-role/MockPolicy"
      name   = "MockPolicy"
      policy = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "the_example_plans" {
  command = plan

  assert {
    condition     = module.api.name == "sls-complete-dev-api"
    error_message = "The naming must join project, environment and function name."
  }
}

run "fan_in_from_two_topics_in_a_single_document" {
  command = plan

  # Two topics publish onto the `events` queue. SQS allows a single Policy attribute per queue: if
  # the fan-in were not declared from the queue side, one of the two policies would survive and the
  # other would vanish silently.
  assert {
    condition     = output.queue_policies.events == tolist(["SnsFromAudit", "SnsFromOperations"])
    error_message = "The two topics must produce two statements in the same queue policy."
  }

  # The ingest queue is authorized by S3, not by a topic.
  assert {
    condition     = output.queue_policies.ingest == tolist(["S3From0"])
    error_message = "The ingest queue must authorize the S3 service alone."
  }
}

run "bucket_notifications_in_a_single_configuration" {
  command = plan

  assert {
    condition     = output.notifications.queues == tolist(["ingest"])
    error_message = "The notification towards the ingest queue must be configured."
  }

  assert {
    condition     = length(output.notifications.functions) == 0
    error_message = "In this example the bucket notifies a queue, not a function."
  }
}

run "no_function_receives_network_permissions" {
  command = plan

  # vpc_name is null in this example: no function is in a VPC, so none must have the ENI
  # permissions.
  assert {
    condition = alltrue([
      output.iam_decisions.api.network == false,
      output.iam_decisions.event_worker.network == false,
      output.iam_decisions.ingest_worker.network == false,
    ])
    error_message = "A function outside the VPC must not receive the network permissions."
  }
}

run "the_consumers_have_the_consumption_permissions" {
  command = plan

  # The function module stops the plan if an event source mapping points at a queue without the
  # consume capability: if this test passes, the coherence is verified.
  assert {
    condition     = output.iam_decisions.event_worker.grants == true
    error_message = "The events consumer must have an application policy."
  }

  assert {
    condition     = output.iam_decisions.ingest_worker.grants == true
    error_message = "The ingest consumer must have an application policy."
  }
}

run "the_secret_value_does_not_go_through_terraform" {
  command = plan

  assert {
    condition     = output.secret_value_in_state == false
    error_message = "The secret's value must not end up in the state."
  }
}
