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
      Project   = "example"
      ManagedBy = "terraform"
    }
  }
}

locals {
  prefix = "${var.name_prefix}-${var.environment}"
}

# ------------------------------------------------------------------------------
# Supporting resources.
#
# They are written natively because this example demonstrates the à-la-carte use of
# modules/function: a real project would use modules/bucket, modules/queue,
# modules/table and modules/secret, and pass their outputs into the same registry.
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "documents" {
  bucket = "${local.prefix}-documents"
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket                  = aws_s3_bucket.documents.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 and not a CMK: it is the same choice modules/bucket makes by default, and it is
# worth keeping here too. A CMK adds rotation, a key policy and auditability, but also a
# billable KMS request for every GET and every PUT when the bucket key is not enough.
# Whoever needs it passes `encryption.kms_key_arn`.
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_dynamodb_table" "tenants" {
  name         = "${local.prefix}-tenants"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# The AWS-managed key and not a CMK, like modules/topic by default: zero cost, and it beats a
# topic in the clear. A CMK is what you need when you need granular key management, or when an
# AWS service publishes — which with `alias/aws/sns` fails with an invisible KMSAccessDenied
# (see modules/topic/README.md). Here only a Lambda publishes, so it is not needed.
#trivy:ignore:AVD-AWS-0136
resource "aws_sns_topic" "events" {
  name = "${local.prefix}-events"

  # The same defaults as modules/topic and modules/queue: the AWS-managed key, zero cost. They
  # have to be written by hand here precisely because these are native resources — it is AWS's
  # default that leaves them in the clear, and an example gets copied.
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sqs_queue" "jobs_dlq" {
  name                      = "${local.prefix}-jobs-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${local.prefix}-jobs"
  visibility_timeout_seconds = 180
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_secretsmanager_secret" "database" {
  name = "${local.prefix}-database"
}

# The registry is built once and passed to every function. In a real project modules/app
# produces it from its own primitives.
locals {
  resources = {
    buckets = {
      documents = { arn = aws_s3_bucket.documents.arn, name = aws_s3_bucket.documents.id }
    }
    tables = {
      tenants = { arn = aws_dynamodb_table.tenants.arn, name = aws_dynamodb_table.tenants.name }
    }
    topics = {
      events = { arn = aws_sns_topic.events.arn, name = aws_sns_topic.events.name }
    }
    queues = {
      jobs     = { arn = aws_sqs_queue.jobs.arn, name = aws_sqs_queue.jobs.name, url = aws_sqs_queue.jobs.url }
      jobs_dlq = { arn = aws_sqs_queue.jobs_dlq.arn, name = aws_sqs_queue.jobs_dlq.name, url = aws_sqs_queue.jobs_dlq.url }
    }
    secrets = {
      database = { arn = aws_secretsmanager_secret.database.arn, name = aws_secretsmanager_secret.database.name }
    }
  }
}

# ------------------------------------------------------------------------------
# An HTTP function: reads from the table, writes to the bucket, publishes events.
# ------------------------------------------------------------------------------

module "api" {
  source = "../../modules/function"

  prefix      = local.prefix
  name        = "api"
  description = "Example HTTP handler"

  package     = { local_path = "${path.module}/dummy.zip" }
  timeout     = 29 # behind an HTTP API Gateway, beyond 29s the gateway answers 504
  memory_size = 512

  resources = local.resources

  env = {
    LOG_LEVEL = "info"
  }

  # The variable's name is just a name: the resource type is declared by the reference, not by
  # the name's prefix.
  env_from = {
    DOCUMENTS_BUCKET = { bucket = "documents" }
    TENANTS_TABLE    = { table = "tenants" }
    EVENTS_TOPIC     = { topic = "events" }
    DATABASE_SECRET  = { secret = "database" }
  }

  grants = {
    "bucket/documents" = ["read", "write"]
    "table/tenants"    = ["read"]
    "topic/events"     = ["publish"]
    "secret/database"  = ["read"]
  }

  observability = {
    log_retention_days = 14
    alarms = {
      actions = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
    }
  }
}

# ------------------------------------------------------------------------------
# A consumer: reads from the queue, and the asynchronous events that exhaust their
# attempts end up in the DLQ instead of disappearing.
# ------------------------------------------------------------------------------

module "worker" {
  source = "../../modules/function"

  prefix      = local.prefix
  name        = "worker"
  description = "Example SQS consumer"

  package     = { local_path = "${path.module}/dummy.zip" }
  timeout     = 60
  memory_size = 256

  resources = local.resources

  env_from = {
    JOBS_QUEUE_URL   = { queue = "jobs" }
    DOCUMENTS_BUCKET = { bucket = "documents" }
  }

  # `consume` on the queue is mandatory for the event source mapping to exist: without the
  # capability the module stops the plan instead of creating a consumer with no permissions,
  # which would never receive a message.
  grants = {
    "queue/jobs"       = ["consume"]
    "queue/jobs_dlq"   = ["publish"]
    "bucket/documents" = ["read", "write"]
  }

  event_sources = {
    jobs = {
      queue = "jobs"
      # With partial failure reporting a single problematic message does not make the whole
      # batch be retried. It requires the handler to return the expected structure, so it is
      # not a default.
      batch_size              = 10
      function_response_types = ["ReportBatchItemFailures"]
    }
  }

  async = {
    on_failure = { queue = "jobs_dlq" }
  }
}

# ------------------------------------------------------------------------------
# A function with no dependencies: it shows the defaults and the absence of network
# permissions.
# ------------------------------------------------------------------------------

module "minimal" {
  source = "../../modules/function"

  prefix  = local.prefix
  name    = "minimal"
  package = { local_path = "${path.module}/dummy.zip" }
}
