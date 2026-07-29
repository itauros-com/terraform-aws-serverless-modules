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
    condition     = module.api.name == "sls-example-dev-api"
    error_message = "The naming must join project prefix, environment and function name."
  }

  assert {
    condition     = module.worker.name == "sls-example-dev-worker"
    error_message = "The consumer's naming must follow the same rule."
  }
}

run "no_function_receives_the_network_permissions" {
  command = plan

  # None of the three functions is in a VPC. In the monolith all of them would have received
  # the ENI policy anyway.
  assert {
    condition = alltrue([
      module.api.iam.network == false,
      module.worker.iam.network == false,
      module.minimal.iam.network == false,
    ])
    error_message = "A function outside the VPC must not receive the network permissions."
  }
}

run "the_minimal_function_has_no_application_policy" {
  command = plan

  assert {
    condition     = module.minimal.policy_json == null
    error_message = "Without grants no application policy must be generated."
  }

  # Tracing and alarms are enabled on the minimal function too: they are defaults, not options
  # to remember.
  assert {
    condition     = module.minimal.iam.tracing == true
    error_message = "Tracing must be enabled by default."
  }

  assert {
    condition     = length(module.minimal.alarm_arns) == 3
    error_message = "The alarms must be created by default even on a function with no dependencies."
  }
}

run "the_consumer_has_a_destination_for_failures" {
  command = plan

  # It is the difference between an asynchronous event that ends up in a DLQ and one that
  # disappears without a trace.
  assert {
    condition     = module.worker.iam.async == true
    error_message = "The consumer must have an on-failure destination and the permissions to write to it."
  }
}
