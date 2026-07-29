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

  mock_data "aws_vpc" {
    defaults = {
      id         = "vpc-0123456789abcdef0"
      cidr_block = "10.20.0.0/16"
    }
  }
}

# The shape of this configuration reproduces the real tfvars the library grew out of: an API
# with a custom authorizer shared between several routes, two topics fanning in onto one queue,
# a consumer with an event source mapping, a bucket with notifications, secrets read by name.
variables {
  prefix = "acme-prod"

  tables = {
    tenants = {
      attributes = { pk = "S", sk = "S", email = "S" }
      hash_key   = "pk"
      range_key  = "sk"

      global_secondary_indexes = {
        by_email = { hash_key = "email" }
      }

      deletion_protection    = false
      point_in_time_recovery = { enabled = false }
    }
  }

  secrets = {
    mongodb = { description = "Connection string" }
  }

  topics = {
    operations = {
      to_queues = { events = {} }
    }
    audit = {
      to_queues = {
        events = { filter_policy = "{\"severity\":[\"critical\"]}" }
      }
    }
  }

  queues = {
    events = {
      visibility_timeout_seconds = 360
    }
    ingest = {
      visibility_timeout_seconds = 360
      allow_send_from_buckets    = ["documents"]
    }
  }

  buckets = {
    documents = {
      force_destroy = true

      notifications = {
        queues = {
          ingest = { queue = "ingest", events = ["s3:ObjectCreated:*"], filter_prefix = "incoming/" }
        }
        functions = {
          thumbnails = { function = "thumbnailer", events = ["s3:ObjectCreated:Put"], filter_suffix = ".jpg" }
        }
      }
    }
  }

  security_groups = {
    lambda = { vpc_name = "acme-prod-vpc" }
  }

  functions = {
    authorizer = {
      image = "111122223333.dkr.ecr.eu-west-1.amazonaws.com/acme-prod/authorizer:v1"

      env_from = {
        SECRET_MONGODB_URI     = { secret = "mongodb" }
        DYNAMODB_TABLE_TENANTS = { table = "tenants" }
      }
      grants = {
        "secret/mongodb" = ["read"]
        "table/tenants"  = ["read"]
      }
    }

    files = {
      image   = "111122223333.dkr.ecr.eu-west-1.amazonaws.com/acme-prod/files:v1"
      timeout = 29

      env = { LOG_LEVEL = "info" }

      env_from = {
        BUCKET_DOCUMENTS   = { bucket = "documents" }
        SECRET_MONGODB_URI = { secret = "mongodb" }
        TOPIC_OPERATIONS   = { topic = "operations" }
        QUEUE_EVENTS       = { queue = "events" }
      }

      grants = {
        "bucket/documents" = ["read", "write"]
        "secret/mongodb"   = ["read"]
        "topic/operations" = ["publish"]
      }

      extra_policy_statements = [
        {
          sid       = "SendEmail"
          actions   = ["ses:SendEmail"]
          resources = ["*"]
        }
      ]
    }

    worker = {
      image   = "111122223333.dkr.ecr.eu-west-1.amazonaws.com/acme-prod/worker:v1"
      timeout = 60

      vpc = {
        subnet_ids          = ["subnet-0123456789abcdef0"]
        security_group_keys = ["lambda"]
      }

      grants = {
        "queue/events"  = ["consume"]
        "table/tenants" = ["read", "write", "scan"]
      }

      event_sources = {
        events = {
          queue                   = "events"
          batch_size              = 10
          function_response_types = ["ReportBatchItemFailures"]
        }
      }

      async = { on_failure_queue = "ingest" }
    }

    thumbnailer = {
      package = { local_path = "fixtures/dummy.zip" }
      timeout = 60

      grants = {
        "queue/ingest"     = ["consume"]
        "bucket/documents" = ["read", "write"]
      }

      event_sources = {
        ingest = { queue = "ingest", batch_size = 5 }
      }
    }
  }

  http_apis = {
    apigw = {
      authorizers = {
        custom = { type = "lambda", function = "authorizer" }
      }

      routes = {
        "ANY /files"          = { function = "files", authorizer = "custom" }
        "ANY /files/{proxy+}" = { function = "files", authorizer = "custom" }
        "GET /health"         = { function = "files" }
      }

      cors = {
        allow_origins = ["https://app.acme.example"]
        allow_methods = ["GET", "POST"]
      }
    }
  }

  registries = {
    files = {
      lambda_read_access_functions = ["files"]
    }
  }

  schedules = {
    cleanup = {
      expression        = "cron(0 3 * * ? *)"
      target_function   = "thumbnailer"
      dead_letter_queue = "ingest"
    }
  }

  sites = {
    web = { spa = true, bucket_force_destroy = true }
  }
}

run "the_whole_application_plans" {
  command = plan

  # That this plan succeeds is a result in itself: the bucket notifies a function and the
  # function reads from the bucket. With real references in both directions Terraform would
  # detect a cycle between the two module blocks.
  assert {
    condition     = output.functions["files"].name == "acme-prod-files"
    error_message = "The naming must join prefix and key."
  }

  assert {
    condition     = length(output.functions) == 4
    error_message = "Four functions must be created."
  }
}

run "subscription_inversion_from_topic_to_queue" {
  command = plan

  # The two topics are declared with `to_queues`, which reads from the topic side. The module
  # inverts it, and two subscriptions land on the queue in a single policy document — which is
  # the only correct way, because SQS allows one Policy per queue.
  assert {
    condition     = output.wiring.queue_subscriptions["events"] == tolist(["audit", "operations"])
    error_message = "The subscriptions declared on the topic side must converge onto the queue."
  }

  assert {
    condition     = length(output.wiring.queue_subscriptions["ingest"]) == 0
    error_message = "The ingest queue receives from no topic."
  }
}

run "static_bucket_arn_in_the_queue_policy" {
  command = plan

  # The ARN is computed from the prefix and not read from the module that creates the bucket:
  # that is what lets the bucket depend on the queue without creating a cycle.
  assert {
    condition     = output.wiring.queue_bucket_sources["ingest"] == tolist(["arn:aws:s3:::acme-prod-documents"])
    error_message = "The queue must authorize the bucket through the ARN computed from the name."
  }
}

run "derived_route_authorization" {
  command = plan

  assert {
    condition = output.wiring.api_route_authorization["apigw"] == {
      "ANY /files"          = "CUSTOM"
      "ANY /files/{proxy+}" = "CUSTOM"
      "GET /health"         = "NONE"
    }
    error_message = "The authorization type must be derived from every route's authorizer."
  }
}

run "invocation_permissions_deduplicated_and_including_the_authorizer" {
  command = plan

  # `files` sits on three routes but receives a single permission; `authorizer` is the target of
  # no route and must still be authorized.
  assert {
    condition     = output.wiring.api_invoked_functions["apigw"] == tolist(["authorizer", "files"])
    error_message = "The functions the API can invoke must be deduplicated and include the authorizer."
  }
}

run "network_permissions_only_to_the_function_in_the_vpc" {
  command = plan

  # In the monolith the ENI policy was attached to every function. Here only `worker` is in a
  # VPC.
  assert {
    condition     = output.wiring.function_iam["worker"].network == true
    error_message = "The function in the VPC must receive the network permissions."
  }

  assert {
    condition = alltrue([
      output.wiring.function_iam["files"].network == false,
      output.wiring.function_iam["authorizer"].network == false,
      output.wiring.function_iam["thumbnailer"].network == false,
    ])
    error_message = "The functions outside the VPC must not receive the network permissions."
  }
}

run "async_destination_and_tracing" {
  command = plan

  assert {
    condition     = output.wiring.function_iam["worker"].async == true
    error_message = "With an on-failure destination the corresponding policy must be attached."
  }

  assert {
    condition     = output.wiring.function_iam["files"].async == false
    error_message = "Without an on-failure destination the policy is not needed."
  }

  assert {
    condition = alltrue([
      for f in values(output.wiring.function_iam) : f.tracing == true
    ])
    error_message = "Tracing must be enabled on every function by default."
  }
}

run "schedule_targets" {
  command = plan

  assert {
    condition     = output.wiring.schedule_targets["cleanup"] == "lambda"
    error_message = "The schedule's target type must be detected from the key used."
  }
}

run "alarm_topic_is_wired" {
  command = plan

  # The topic is created before the primitives and its ARN ends up in everyone's alarms: there
  # is no such case as an alarm created and not delivered.
  assert {
    condition     = length(local.alarm_actions) == 1
    error_message = "The alarm topic must be wired into every primitive's alarms."
  }

  assert {
    condition     = output.dashboard_name == "acme-prod-app"
    error_message = "The dashboard must be created with the application's name."
  }
}

run "observability_can_be_disabled" {
  command = plan

  variables {
    observability = { enabled = false }
  }

  assert {
    condition     = output.alarm_topic_arn == null
    error_message = "With observability disabled the alarm topic must not exist."
  }

  assert {
    condition     = length(local.alarm_actions) == 0
    error_message = "Without a topic the alarms must have no actions."
  }
}

run "minimal_application" {
  command = plan

  variables {
    tables          = {}
    secrets         = {}
    topics          = {}
    queues          = {}
    buckets         = {}
    security_groups = {}
    http_apis       = {}
    registries      = {}
    schedules       = {}
    sites           = {}

    functions = {
      hello = {
        package = { local_path = "fixtures/dummy.zip" }
      }
    }
  }

  assert {
    condition     = length(output.functions) == 1
    error_message = "A single function with no dependencies must be able to be the whole application."
  }

  assert {
    condition     = length(output.resources.buckets) == 0
    error_message = "With no declared buckets the registry must be empty."
  }
}
