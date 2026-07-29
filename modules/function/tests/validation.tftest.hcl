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
  name    = "files"
  prefix  = "acme-prod"
  package = { local_path = "fixtures/dummy.zip" }

  resources = {
    buckets = {
      documents = { arn = "arn:aws:s3:::acme-prod-documents", name = "acme-prod-documents" }
    }
    queues = {
      # Deliberately without `url`: this covers the case where the resource exists
      # but does not expose the requested attribute.
      emails = { arn = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-emails", name = "acme-prod-emails" }
    }
  }
}

run "env_from_towards_a_nonexistent_resource" {
  command = plan

  variables {
    env_from = {
      DOCS = { bucket = "documnets" }
    }
  }

  # In the previous wiring this typo did not stop the plan: the Lambda received
  # `documnets` as a literal value and found out at runtime.
  expect_failures = [var.env_from]
}

run "env_from_with_two_types" {
  command = plan

  variables {
    env_from = {
      DOCS = { bucket = "documents", queue = "emails" }
    }
  }

  expect_failures = [var.env_from]
}

run "env_from_without_a_type" {
  command = plan

  variables {
    env_from = {
      DOCS = { attr = "arn" }
    }
  }

  expect_failures = [var.env_from]
}

run "env_from_with_an_invalid_attr" {
  command = plan

  variables {
    env_from = {
      DOCS = { bucket = "documents", attr = "id" }
    }
  }

  expect_failures = [var.env_from]
}

run "env_from_towards_an_unpopulated_attribute" {
  command = plan

  variables {
    # The `emails` queue exists but has no `url`: the default for queues is exactly
    # `url`, so the reference does not resolve and the plan must stop.
    env_from = {
      EMAILS_URL = { queue = "emails" }
    }
  }

  expect_failures = [output.arn]
}

run "event_source_on_a_queue_without_the_consume_capability" {
  command = plan

  variables {
    event_sources = {
      emails = { queue = "emails" }
    }
    grants = {
      "queue/emails" = ["publish"]
    }
  }

  # A mapping without consumption permissions exists, receives nothing and raises no
  # error: exactly the kind of divergence that must stop the plan.
  expect_failures = [var.event_sources]
}

run "event_source_towards_a_nonexistent_queue" {
  command = plan

  variables {
    event_sources = {
      other = { queue = "nonexistent" }
    }
  }

  expect_failures = [var.event_sources]
}

run "event_source_without_a_source" {
  command = plan

  variables {
    event_sources = {
      emails = {}
    }
  }

  expect_failures = [var.event_sources]
}

run "event_source_with_two_sources" {
  command = plan

  variables {
    event_sources = {
      emails = {
        queue            = "emails"
        event_source_arn = "arn:aws:sqs:eu-west-1:111122223333:other"
      }
    }
    grants = {
      "queue/emails" = ["consume"]
    }
  }

  expect_failures = [var.event_sources]
}

run "package_with_both_local_path_and_s3" {
  command = plan

  variables {
    package = {
      local_path = "fixtures/dummy.zip"
      s3_bucket  = "acme-artifacts"
      s3_key     = "files.zip"
    }
  }

  expect_failures = [var.package]
}

run "async_on_failure_with_two_destinations" {
  command = plan

  variables {
    async = {
      on_failure = {
        queue = "emails"
        arn   = "arn:aws:sns:eu-west-1:111122223333:other"
      }
    }
  }

  expect_failures = [var.async]
}

run "async_destination_towards_a_nonexistent_resource" {
  command = plan

  variables {
    async = {
      on_failure = { queue = "nonexistent" }
    }
  }

  # A destination declared and not resolved is worse than none at all: the function
  # looks protected against losing asynchronous events and it is not.
  expect_failures = [output.arn]
}

run "async_with_too_many_attempts" {
  command = plan

  variables {
    async = {
      maximum_retry_attempts = 5
    }
  }

  expect_failures = [var.async]
}

run "unsupported_architecture" {
  command = plan

  variables {
    architectures = ["arm64", "x86_64"]
  }

  expect_failures = [var.architectures]
}

run "timeout_out_of_range" {
  command = plan

  variables {
    timeout = 1000
  }

  expect_failures = [var.timeout]
}

run "memory_out_of_range" {
  command = plan

  variables {
    memory_size = 64
  }

  expect_failures = [var.memory_size]
}

run "vpc_without_subnets" {
  command = plan

  variables {
    vpc = {
      subnet_ids         = []
      security_group_ids = ["sg-0123456789abcdef0"]
    }
  }

  expect_failures = [var.vpc]
}

run "invalid_log_format" {
  command = plan

  variables {
    observability = {
      log_format = "Structured"
    }
  }

  expect_failures = [var.observability]
}

run "duration_ratio_out_of_range" {
  command = plan

  variables {
    observability = {
      alarms = { duration_threshold_ratio = 1.5 }
    }
  }

  expect_failures = [var.observability]
}

# Grant validation (nonexistent resource, capability unknown for the service) is
# delegated to modules/grants and covered by its tests. It is not reproducible here:
# `expect_failures` only accepts checkable objects of the configuration under test,
# not the outputs of a child module. Duplicating the validation logic in this module
# to make it testable would be the wrong remedy — the single source of truth remains
# the capability table.
