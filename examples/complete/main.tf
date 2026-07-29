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

  # S3 ARNs are deterministic from the name. Computing them here breaks the cycle: the queue must
  # authorize S3 to write to it, and the bucket needs the queue's ARN for the notification.
  documents_bucket_arn = "arn:aws:s3:::${local.prefix}-documents"
}

# ------------------------------------------------------------------------------
# Data
# ------------------------------------------------------------------------------

module "tenants" {
  source = "../../modules/table"

  prefix = local.prefix
  name   = "tenants"

  attributes = { pk = "S", sk = "S", email = "S" }
  hash_key   = "pk"
  range_key  = "sk"

  global_secondary_indexes = {
    by_email = { hash_key = "email" }
  }

  ttl = { enabled = true, attribute_name = "expires_at" }

  # A throwaway example: without this the destroy does not work.
  deletion_protection    = false
  point_in_time_recovery = { enabled = false }
}

module "documents" {
  source = "../../modules/bucket"

  prefix = local.prefix
  name   = "documents"

  force_destroy = true

  lifecycle_rules = [
    {
      id                                     = "pulizia"
      noncurrent_version_expiration          = { noncurrent_days = 7 }
      abort_incomplete_multipart_upload_days = 7
    }
  ]

  # All the notifications in a single input: S3 allows one configuration per bucket and every
  # write replaces the previous one.
  notifications = {
    queues = {
      ingest = {
        queue_arn     = module.ingest.arn
        events        = ["s3:ObjectCreated:*"]
        filter_prefix = "incoming/"
      }
    }
  }
}

module "database_secret" {
  source = "../../modules/secret"

  prefix      = local.prefix
  name        = "database"
  description = "Connection string. Created empty, populated outside Terraform."

  recovery_window_in_days = 0 # ambiente usa e getta
}

# ------------------------------------------------------------------------------
# Messaging
#
# Two topics publish onto the same `events` queue: it is the fan-in case that requires a
# single policy document with one statement per topic, and that can only be declared
# correctly from the queue side.
# ------------------------------------------------------------------------------

module "operations" {
  source = "../../modules/topic"

  prefix = local.prefix
  name   = "operations"
}

module "audit" {
  source = "../../modules/topic"

  prefix = local.prefix
  name   = "audit"
}

module "events" {
  source = "../../modules/queue"

  prefix = local.prefix
  name   = "events"

  # Six times the consumer's timeout.
  visibility_timeout_seconds = 360

  subscriptions = {
    operations = { topic_arn = module.operations.arn }
    audit = {
      topic_arn     = module.audit.arn
      filter_policy = jsonencode({ severity = ["critical"] })
    }
  }
}

module "ingest" {
  source = "../../modules/queue"

  prefix = local.prefix
  name   = "ingest"

  visibility_timeout_seconds = 360

  # The ARN as a string and not as a reference to the module: the bucket depends on this queue
  # for the notification, and a reverse reference would be a cycle.
  allow_send_from = [
    { service = "s3", source_arn = local.documents_bucket_arn },
  ]
}

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------

module "lambda_sg" {
  source = "../../modules/security-group"

  count = var.vpc_name == null ? 0 : 1

  prefix   = local.prefix
  name     = "lambda"
  vpc_name = var.vpc_name
}

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------

locals {
  # The registry is composed once from the primitives' ready-made entries. The registry_entry
  # values also carry the CMK, which is how the KMS permissions do not get forgotten.
  resources = {
    tables  = { tenants = module.tenants.registry_entry }
    buckets = { documents = module.documents.registry_entry }
    secrets = { database = module.database_secret.registry_entry }
    topics = {
      operations = module.operations.registry_entry
      audit      = module.audit.registry_entry
    }
    queues = {
      events = module.events.registry_entry
      ingest = module.ingest.registry_entry
    }
  }

  vpc = var.vpc_name == null ? null : {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [module.lambda_sg[0].id]
  }
}

module "api" {
  source = "../../modules/function"

  prefix      = local.prefix
  name        = "api"
  description = "HTTP handler"

  package     = { local_path = "${path.module}/dummy.zip" }
  timeout     = 29
  memory_size = 512

  resources = local.resources
  vpc       = local.vpc

  env = { LOG_LEVEL = "info" }

  env_from = {
    TENANTS_TABLE    = { table = "tenants" }
    DOCUMENTS_BUCKET = { bucket = "documents" }
    DATABASE_SECRET  = { secret = "database" }
    OPERATIONS_TOPIC = { topic = "operations" }
  }

  grants = {
    "table/tenants"    = ["read", "write"]
    "bucket/documents" = ["read", "write"]
    "secret/database"  = ["read"]
    "topic/operations" = ["publish"]
  }
}

module "event_worker" {
  source = "../../modules/function"

  prefix      = local.prefix
  name        = "event-worker"
  description = "Consumes the events from the two topics"

  package     = { local_path = "${path.module}/dummy.zip" }
  timeout     = 60
  memory_size = 256

  resources = local.resources
  vpc       = local.vpc

  env_from = {
    TENANTS_TABLE = { table = "tenants" }
  }

  grants = {
    "queue/events"  = ["consume"]
    "table/tenants" = ["read", "write"]
  }

  event_sources = {
    events = {
      queue                   = "events"
      batch_size              = 10
      function_response_types = ["ReportBatchItemFailures"]
    }
  }

  # The asynchronous events that exhaust their attempts end up in the ingest queue's DLQ instead
  # of disappearing.
  async = {
    on_failure = { queue = "ingest" }
  }
}

module "ingest_worker" {
  source = "../../modules/function"

  prefix      = local.prefix
  name        = "ingest-worker"
  description = "Processes the files uploaded to the bucket"

  package     = { local_path = "${path.module}/dummy.zip" }
  timeout     = 60
  memory_size = 1024

  resources = local.resources
  vpc       = local.vpc

  env_from = {
    DOCUMENTS_BUCKET = { bucket = "documents" }
    AUDIT_TOPIC      = { topic = "audit" }
  }

  grants = {
    "queue/ingest"     = ["consume"]
    "bucket/documents" = ["read", "write"]
    "topic/audit"      = ["publish"]
  }

  event_sources = {
    ingest = {
      queue                   = "ingest"
      batch_size              = 5
      function_response_types = ["ReportBatchItemFailures"]
    }
  }
}
