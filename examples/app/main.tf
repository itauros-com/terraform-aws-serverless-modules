terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# This is all a root config needs: a backend, a provider and one call. The rest is the
# description of the application.
module "app" {
  source = "../../modules/app"

  prefix = "${var.project}-${var.environment}"

  tags = {
    Application = var.project
  }

  # ----------------------------------------------------------------------------
  # Data
  # ----------------------------------------------------------------------------

  tables = {
    tenants = {
      attributes = { pk = "S", sk = "S", email = "S" }
      hash_key   = "pk"
      range_key  = "sk"

      global_secondary_indexes = {
        by_email = { hash_key = "email" }
      }

      ttl = { enabled = true, attribute_name = "expires_at" }

      # A throwaway example: the module's defaults protect the data, and here there is none.
      deletion_protection    = false
      point_in_time_recovery = { enabled = false }
    }
  }

  buckets = {
    documents = {
      force_destroy = true

      lifecycle_rules = [
        {
          id                                     = "pulizia"
          noncurrent_version_expiration          = { noncurrent_days = 7 }
          abort_incomplete_multipart_upload_days = 7
        }
      ]

      # The notifications reference the queue and the function by key.
      notifications = {
        queues = {
          ingest = { queue = "ingest", events = ["s3:ObjectCreated:*"], filter_prefix = "incoming/" }
        }
        functions = {
          indexer = { function = "indexer", events = ["s3:ObjectCreated:Put"], filter_suffix = ".pdf" }
        }
      }
    }
  }

  secrets = {
    mongodb = { description = "Connection string. Created empty, populated outside Terraform." }
  }

  # ----------------------------------------------------------------------------
  # Messaging
  #
  # Two topics publish onto the same queue: the module inverts the declarations towards
  # the queue side, where the two authorizations converge into a single policy document.
  # ----------------------------------------------------------------------------

  topics = {
    operations = {
      to_queues = { events = {} }
    }
    audit = {
      to_queues = {
        events = { filter_policy = jsonencode({ severity = ["critical"] }) }
      }
    }
  }

  queues = {
    events = {
      # Six times the consumer's timeout.
      visibility_timeout_seconds = 360
    }
    ingest = {
      visibility_timeout_seconds = 360
      allow_send_from_buckets    = ["documents"]
    }
  }

  # ----------------------------------------------------------------------------
  # Functions
  # ----------------------------------------------------------------------------

  functions = {
    authorizer = {
      package     = { local_path = "${path.module}/dummy.zip" }
      description = "Authorizer REQUEST"

      env_from = {
        TENANTS_TABLE = { table = "tenants" }
        MONGO_SECRET  = { secret = "mongodb" }
      }

      grants = {
        "table/tenants"  = ["read"]
        "secret/mongodb" = ["read"]
      }
    }

    files = {
      package     = { local_path = "${path.module}/dummy.zip" }
      description = "Handler HTTP"
      timeout     = 29
      memory_size = 512

      env = { LOG_LEVEL = "info" }

      # The variable's name is just a name: the type is declared by the reference, not by
      # the prefix.
      env_from = {
        DOCUMENTS_BUCKET = { bucket = "documents" }
        TENANTS_TABLE    = { table = "tenants" }
        OPERATIONS_TOPIC = { topic = "operations" }
        MONGO_SECRET     = { secret = "mongodb" }
      }

      grants = {
        "bucket/documents" = ["read", "write"]
        "table/tenants"    = ["read", "write"]
        "topic/operations" = ["publish"]
        "secret/mongodb"   = ["read"]
      }

      # Escape hatch for the services outside the capability table.
      extra_policy_statements = [
        {
          sid       = "SendEmail"
          actions   = ["ses:SendEmail", "ses:SendRawEmail"]
          resources = ["*"]
          condition = [
            { test = "StringEquals", variable = "aws:RequestedRegion", values = [var.region] }
          ]
        }
      ]
    }

    worker = {
      package     = { local_path = "${path.module}/dummy.zip" }
      description = "Consumes the events from the two topics"
      timeout     = 60

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

      # The asynchronous events that exhaust their attempts end up in the ingest queue's
      # DLQ instead of disappearing.
      async = { on_failure_queue = "ingest" }
    }

    indexer = {
      package     = { local_path = "${path.module}/dummy.zip" }
      description = "Indexes the uploaded documents"
      timeout     = 120
      memory_size = 1024

      grants = {
        "queue/ingest"     = ["consume"]
        "bucket/documents" = ["read"]
        "table/tenants"    = ["read", "write"]
      }

      event_sources = {
        ingest = { queue = "ingest", batch_size = 5, function_response_types = ["ReportBatchItemFailures"] }
      }
    }
  }

  # ----------------------------------------------------------------------------
  # External surface
  # ----------------------------------------------------------------------------

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
        allow_origins = ["https://app.example"]
        allow_methods = ["GET", "POST", "PUT", "DELETE"]
      }
    }
  }

  sites = {
    web = {
      spa                  = true
      bucket_force_destroy = true
    }
  }

  registries = {
    files = {
      lambda_read_access_functions = ["files"]
    }
  }

  schedules = {
    cleanup = {
      description       = "Pulizia notturna"
      expression        = "cron(0 3 * * ? *)"
      timezone          = "Europe/Rome"
      target_function   = "worker"
      input             = jsonencode({ job = "cleanup" })
      dead_letter_queue = "ingest"
    }
  }

  # ----------------------------------------------------------------------------
  # Observability
  #
  # The alarm topic is created before the primitives and wired into all of them.
  # ----------------------------------------------------------------------------

  observability = {
    alarm_subscriptions = var.oncall_email == null ? {} : {
      oncall = { protocol = "email", endpoint = var.oncall_email }
    }

    composite_alarm_enabled = true
  }
}
