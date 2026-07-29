# The values the mocks generate automatically do not pass the provider's validation
# (random partition in the ARNs, policies that are not JSON), so the data sources the
# upstream module uses have to be mocked with plausible values.
# None of these values is the subject of an assertion: the policies we care about are
# built by modules/grants with jsonencode, not by the provider.
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

variables {
  prefix = "acme-prod"

  resources = {
    buckets = {
      documents = { arn = "arn:aws:s3:::acme-prod-documents", name = "acme-prod-documents" }
    }
    tables = {
      tenants = { arn = "arn:aws:dynamodb:eu-west-1:111122223333:table/acme-prod-tenants", name = "acme-prod-tenants" }
    }
    topics = {
      operations = { arn = "arn:aws:sns:eu-west-1:111122223333:acme-prod-operations", name = "acme-prod-operations" }
    }
    queues = {
      emails = {
        arn  = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-emails"
        name = "acme-prod-emails"
        url  = "https://sqs.eu-west-1.amazonaws.com/111122223333/acme-prod-emails"
      }
      failures = { arn = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-failures", name = "acme-prod-failures" }
    }
    secrets = {
      mongodb = { arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:acme-prod-mongodb-AbCdEf", name = "acme-prod-mongodb" }
    }
  }
}

run "naming_with_a_prefix" {
  command = plan

  variables {
    name    = "files"
    package = { local_path = "fixtures/dummy.zip" }
  }

  assert {
    condition     = output.name == "acme-prod-files"
    error_message = "The final name must be <prefix>-<name>."
  }
}

run "naming_without_a_prefix" {
  command = plan

  variables {
    name    = "acme-prod-files"
    prefix  = null
    package = { local_path = "fixtures/dummy.zip" }
  }

  assert {
    condition     = output.name == "acme-prod-files"
    error_message = "Without a prefix the name must be used as is."
  }
}

run "env_from_resolves_the_right_attribute_per_type" {
  command = plan

  variables {
    name    = "files"
    package = { local_path = "fixtures/dummy.zip" }

    env = {
      LOG_LEVEL = "info"
    }
    env_from = {
      DOCS_BUCKET = { bucket = "documents" }
      TENANTS_TBL = { table = "tenants" }
      EVENTS_ARN  = { topic = "operations" }
      EMAILS_URL  = { queue = "emails" }
      MONGO_NAME  = { secret = "mongodb" }
    }

    grants = {
      "bucket/documents" = ["read"]
      "table/tenants"    = ["read"]
      "topic/operations" = ["publish"]
      "queue/emails"     = ["publish"]
      "secret/mongodb"   = ["read"]
    }
  }

  # The per-type defaults reproduce what the application expects: name for buckets,
  # tables and secrets; ARN for topics; URL for queues.
  assert {
    condition     = output.environment_variables["DOCS_BUCKET"] == "acme-prod-documents"
    error_message = "A bucket reference must resolve to the bucket's name."
  }

  assert {
    condition     = output.environment_variables["TENANTS_TBL"] == "acme-prod-tenants"
    error_message = "A table reference must resolve to the table's name."
  }

  assert {
    condition     = output.environment_variables["EVENTS_ARN"] == "arn:aws:sns:eu-west-1:111122223333:acme-prod-operations"
    error_message = "A topic reference must resolve to the ARN."
  }

  assert {
    condition     = output.environment_variables["EMAILS_URL"] == "https://sqs.eu-west-1.amazonaws.com/111122223333/acme-prod-emails"
    error_message = "A queue reference must resolve to the URL."
  }

  assert {
    condition     = output.environment_variables["MONGO_NAME"] == "acme-prod-mongodb"
    error_message = "A secret reference must resolve to the name."
  }

  assert {
    condition     = output.environment_variables["LOG_LEVEL"] == "info"
    error_message = "Literal values must pass through unchanged."
  }
}

run "an_explicit_attr_overrides_the_default" {
  command = plan

  variables {
    name    = "files"
    package = { local_path = "fixtures/dummy.zip" }
    env_from = {
      DOCS_ARN = { bucket = "documents", attr = "arn" }
    }
  }

  assert {
    condition     = output.environment_variables["DOCS_ARN"] == "arn:aws:s3:::acme-prod-documents"
    error_message = "An explicit attr must win over the per-type default."
  }
}

run "the_variable_name_does_not_affect_resolution" {
  command = plan

  variables {
    name    = "files"
    package = { local_path = "fixtures/dummy.zip" }
    env_from = {
      # In the previous wiring the name's prefix decided the behaviour: `BUCKET_X`
      # resolved to a bucket. Here the names are deliberately misleading and must be
      # ignored.
      SNS_TOPIC_SOMETHING = { bucket = "documents" }
      BUCKET_SOMETHING    = { topic = "operations" }
    }
  }

  assert {
    condition     = output.environment_variables["SNS_TOPIC_SOMETHING"] == "acme-prod-documents"
    error_message = "The environment variable's name must not affect the resolution."
  }

  assert {
    condition     = output.environment_variables["BUCKET_SOMETHING"] == "arn:aws:sns:eu-west-1:111122223333:acme-prod-operations"
    error_message = "The environment variable's name must not affect the resolution."
  }
}

run "policy_generated_from_the_grants" {
  command = plan

  variables {
    name    = "files"
    package = { local_path = "fixtures/dummy.zip" }
    grants = {
      "bucket/documents" = ["read", "write"]
      "secret/mongodb"   = ["read"]
    }
  }

  assert {
    condition     = output.iam.grants == true
    error_message = "With grants the policy must be attached."
  }

  assert {
    condition = [for s in jsondecode(output.policy_json).Statement : s.Sid] == [
      "BucketDocumentsChildren", "BucketDocumentsSelf", "SecretMongodbSelf",
    ]
    error_message = "The policy must contain the statements generated by modules/grants."
  }
}

run "no_grants_no_policy" {
  command = plan

  variables {
    name    = "files"
    package = { local_path = "fixtures/dummy.zip" }
  }

  assert {
    condition     = output.policy_json == null
    error_message = "Without grants no policy must be generated."
  }

  assert {
    condition     = output.iam.grants == false
    error_message = "Without grants no policy must be attached."
  }
}

run "network_permissions_only_inside_the_vpc" {
  command = plan

  variables {
    name    = "worker"
    package = { local_path = "fixtures/dummy.zip" }
  }

  # This is the correction of a real widening: in the monolith the VPC policy was
  # attached to every function, including the 34 that are not in a VPC.
  assert {
    condition     = output.iam.network == false
    error_message = "A function without vpc must not receive the network permissions."
  }
}

run "network_permissions_with_the_vpc" {
  command = plan

  variables {
    name    = "worker"
    package = { local_path = "fixtures/dummy.zip" }
    vpc = {
      subnet_ids         = ["subnet-0123456789abcdef0"]
      security_group_ids = ["sg-0123456789abcdef0"]
    }
  }

  assert {
    condition     = output.iam.network == true
    error_message = "A function in a VPC must receive the network permissions."
  }
}

run "container_image" {
  command = plan

  variables {
    name      = "worker"
    image_uri = "111122223333.dkr.ecr.eu-west-1.amazonaws.com/acme/worker:v1.2.3"
  }

  assert {
    condition     = output.name == "acme-prod-worker"
    error_message = "A container function must be created like the others."
  }
}

run "alarms_enabled_by_default" {
  command = plan

  variables {
    name    = "files"
    package = { local_path = "fixtures/dummy.zip" }
    timeout = 30
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.errors) == 1
    error_message = "The alarm on errors must be enabled by default."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.throttles) == 1
    error_message = "The alarm on throttles must be enabled by default."
  }

  # 30s of timeout × 0.8 = 24000 ms: the threshold follows the timeout instead of
  # being an absolute value that ages.
  assert {
    condition     = aws_cloudwatch_metric_alarm.duration[0].threshold == 24000
    error_message = "The duration threshold must be the configured fraction of the timeout, in milliseconds."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.errors[0].treat_missing_data == "notBreaching"
    error_message = "No invocations is not an error: missing data must not trip the alarm."
  }
}

run "alarms_can_be_disabled_for_a_migration_at_parity_of_resources" {
  command = plan

  variables {
    name    = "files"
    package = { local_path = "fixtures/dummy.zip" }
    observability = {
      alarms  = { enabled = false }
      tracing = false
    }
    async = { enabled = false }
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.errors) == 0
    error_message = "alarms.enabled = false must create no alarm."
  }

  assert {
    condition     = length(output.alarm_arns) == 0
    error_message = "Without alarms the output must be an empty map."
  }

  assert {
    condition     = output.iam.tracing == false
    error_message = "tracing = false must not attach the tracing policy."
  }
}

run "on_failure_destination_from_a_reference" {
  command = plan

  variables {
    name    = "notifier"
    package = { local_path = "fixtures/dummy.zip" }
    async = {
      on_failure = { queue = "failures" }
    }
    grants = {
      "queue/failures" = ["publish"]
    }
  }

  assert {
    condition     = output.iam.async == true
    error_message = "With an on-failure destination the corresponding policy must be attached."
  }
}

run "event_source_from_a_queue_reference" {
  command = plan

  variables {
    name    = "consumer"
    package = { local_path = "fixtures/dummy.zip" }
    event_sources = {
      emails = {
        queue                   = "emails"
        batch_size              = 10
        function_response_types = ["ReportBatchItemFailures"]
      }
    }
    grants = {
      "queue/emails" = ["consume"]
    }
  }

  assert {
    condition     = output.iam.grants == true
    error_message = "A consumer must have the consumption policy."
  }

  assert {
    condition = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "QueueEmailsSelf"]).Action == [
      "sqs:ChangeMessageVisibility", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ReceiveMessage",
    ]
    error_message = "consume must generate the four consumption actions."
  }
}
