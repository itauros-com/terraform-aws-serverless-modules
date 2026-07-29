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

variables {
  prefix = "acme-prod"

  functions = {
    api = {
      package = { local_path = "fixtures/dummy.zip" }
    }
  }
}

run "invalid_prefix" {
  command = plan

  variables {
    prefix = "Acme_Prod"
  }

  # The prefix ends up in the buckets' names, which are globally unique and have a restricted
  # charset.
  expect_failures = [var.prefix]
}

run "function_with_both_an_image_and_a_package" {
  command = plan

  variables {
    functions = {
      api = {
        image   = "111122223333.dkr.ecr.eu-west-1.amazonaws.com/acme/api:v1"
        package = { local_path = "fixtures/dummy.zip" }
      }
    }
  }

  expect_failures = [var.functions]
}

run "function_without_code" {
  command = plan

  variables {
    functions = {
      api = {}
    }
  }

  expect_failures = [var.functions]
}

run "schedule_with_two_targets" {
  command = plan

  variables {
    queues = { jobs = {} }
    schedules = {
      cleanup = {
        expression      = "rate(1 day)"
        target_function = "api"
        target_queue    = "jobs"
      }
    }
  }

  expect_failures = [var.schedules]
}

# ------------------------------------------------------------------------------
# Cross-references by key.
#
# All reported by `wiring`'s precondition, which names them one by one instead of
# letting an "Invalid index" surface on a module block.
# ------------------------------------------------------------------------------

run "topic_towards_a_nonexistent_queue" {
  command = plan

  variables {
    queues = { events = {} }
    topics = {
      operations = { to_queues = { eventi = {} } }
    }
  }

  expect_failures = [output.wiring]
}

run "queue_authorizes_a_nonexistent_bucket" {
  command = plan

  variables {
    queues = {
      ingest = { allow_send_from_buckets = ["documenti"] }
    }
    buckets = { documents = {} }
  }

  expect_failures = [output.wiring]
}

run "notification_towards_a_nonexistent_queue" {
  command = plan

  variables {
    queues = { ingest = {} }
    buckets = {
      documents = {
        notifications = {
          queues = {
            n = { queue = "nonexistent", events = ["s3:ObjectCreated:*"] }
          }
        }
      }
    }
  }

  expect_failures = [output.wiring]
}

run "notification_towards_a_nonexistent_topic" {
  command = plan

  variables {
    buckets = {
      documents = {
        notifications = {
          topics = {
            n = { topic = "nonexistent", events = ["s3:ObjectRemoved:*"] }
          }
        }
      }
    }
  }

  expect_failures = [output.wiring]
}

run "notification_towards_a_nonexistent_function" {
  command = plan

  variables {
    buckets = {
      documents = {
        notifications = {
          functions = {
            n = { function = "nonexistent", events = ["s3:ObjectCreated:*"] }
          }
        }
      }
    }
  }

  expect_failures = [output.wiring]
}

run "function_with_a_nonexistent_security_group" {
  command = plan

  variables {
    security_groups = { lambda = { vpc_name = "acme-prod-vpc" } }

    functions = {
      api = {
        package = { local_path = "fixtures/dummy.zip" }
        vpc = {
          subnet_ids          = ["subnet-0123456789abcdef0"]
          security_group_keys = ["lambdas"]
        }
      }
    }
  }

  expect_failures = [output.wiring]
}

run "async_destination_towards_a_nonexistent_queue" {
  command = plan

  variables {
    queues = { jobs = {} }

    functions = {
      api = {
        package = { local_path = "fixtures/dummy.zip" }
        async   = { on_failure_queue = "job" }
      }
    }
  }

  expect_failures = [output.wiring]
}

run "async_destination_towards_a_nonexistent_topic" {
  command = plan

  variables {
    functions = {
      api = {
        package = { local_path = "fixtures/dummy.zip" }
        async   = { on_failure_topic = "nonexistent" }
      }
    }
  }

  expect_failures = [output.wiring]
}

run "schedule_towards_a_nonexistent_function" {
  command = plan

  variables {
    schedules = {
      cleanup = {
        expression                = "rate(1 day)"
        target_function           = "apy"
        allow_missing_dead_letter = true
      }
    }
  }

  expect_failures = [output.wiring]
}

run "schedule_with_the_dlq_of_a_nonexistent_queue" {
  command = plan

  variables {
    schedules = {
      cleanup = {
        expression        = "rate(1 day)"
        target_function   = "api"
        dead_letter_queue = "nonexistent"
      }
    }
  }

  expect_failures = [output.wiring]
}

run "registry_towards_a_nonexistent_function" {
  command = plan

  variables {
    registries = {
      api = { lambda_read_access_functions = ["apy"] }
    }
  }

  expect_failures = [output.wiring]
}

run "site_and_bucket_with_the_same_key" {
  command = plan

  variables {
    buckets = { web = {} }
    sites   = { web = {} }
  }

  # They would generate two buckets with the same name, and the error would come from AWS at
  # apply time.
  expect_failures = [output.wiring]
}
