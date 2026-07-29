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

run "the_application_plans" {
  command = plan

  assert {
    condition     = output.function_names["files"] == "sls-app-dev-files"
    error_message = "The naming must join project, environment and function key."
  }

  assert {
    condition     = length(output.function_names) == 4
    error_message = "Four functions must be created."
  }
}

run "the_fan_in_converges_onto_one_queue" {
  command = plan

  # Two topics publish onto `events`: the two authorizations must live in a single policy
  # document, because SQS allows one per queue.
  assert {
    condition     = output.wiring.queue_subscriptions["events"] == tolist(["audit", "operations"])
    error_message = "The subscriptions declared on the topic side must converge onto the queue."
  }
}

run "the_bucket_function_cycle_is_broken" {
  command = plan

  # The bucket notifies `indexer` and `indexer` reads from the bucket. That this plan succeeds is
  # the proof that the bucket registry is computed and not read.
  assert {
    condition     = output.wiring.queue_bucket_sources["ingest"] == tolist(["arn:aws:s3:::sls-app-dev-documents"])
    error_message = "The queue must authorize the bucket through the ARN computed from the name."
  }
}

run "which_routes_are_public" {
  command = plan

  # It is the question this output exists to answer without cross-referencing two fields of the
  # configuration.
  assert {
    condition = output.wiring.api_route_authorization["apigw"] == {
      "ANY /files"          = "CUSTOM"
      "ANY /files/{proxy+}" = "CUSTOM"
      "GET /health"         = "NONE"
    }
    error_message = "Only the health route must be public."
  }
}

run "no_function_has_network_permissions" {
  command = plan

  # No function in this example is in a VPC. In the monolith all of them would have received the
  # ENI policy anyway.
  assert {
    condition = alltrue([
      for f in values(output.wiring.function_iam) : f.network == false
    ])
    error_message = "A function outside the VPC must not receive the network permissions."
  }

  # Only `worker` declares an on-failure destination.
  assert {
    condition     = output.wiring.function_iam["worker"].async == true
    error_message = "The consumer must have an on-failure destination and the permissions to write to it."
  }
}

run "observability_is_wired" {
  command = plan

  assert {
    condition     = output.dashboard_name == "sls-app-dev-app"
    error_message = "The dashboard must be created."
  }
}
