variable "prefix" {
  description = <<-EOT
    Naming prefix for every resource, typically `<project>-<environment>`.

    It is an input and not a value derived from the workspace: the module knows nothing about
    environments, and the choice of which environment it is building belongs to the root config
    that calls it.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$", var.prefix))
    error_message = "prefix must be lowercase, contain only letters, digits and dashes, and be between 3 and 50 characters: it ends up in the buckets' names, which are globally unique and have a restricted charset."
  }
}

variable "tags" {
  description = "Tags applied to every resource created."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# Data
# ------------------------------------------------------------------------------

variable "tables" {
  description = "DynamoDB tables. The key becomes the name's suffix and the reference used in `grants` and `env_from`."
  type = map(object({
    attributes = map(string)
    hash_key   = string
    range_key  = optional(string)

    billing_mode   = optional(string, "PAY_PER_REQUEST")
    read_capacity  = optional(number)
    write_capacity = optional(number)
    table_class    = optional(string, "STANDARD")

    global_secondary_indexes = optional(map(object({
      hash_key           = string
      range_key          = optional(string)
      projection_type    = optional(string, "ALL")
      non_key_attributes = optional(list(string))
      read_capacity      = optional(number)
      write_capacity     = optional(number)
    })), {})

    local_secondary_indexes = optional(map(object({
      range_key          = string
      projection_type    = optional(string, "ALL")
      non_key_attributes = optional(list(string))
    })), {})

    ttl = optional(object({
      enabled        = optional(bool, false)
      attribute_name = optional(string, "expires_at")
    }), {})

    point_in_time_recovery = optional(object({
      enabled        = optional(bool, true)
      period_in_days = optional(number)
    }), {})

    deletion_protection = optional(bool, true)

    stream = optional(object({
      enabled   = optional(bool, false)
      view_type = optional(string, "NEW_AND_OLD_IMAGES")
    }), {})

    kms_key_arn = optional(string)
    tags        = optional(map(string), {})
  }))
  default = {}
}

variable "buckets" {
  description = <<-EOT
    S3 buckets. Always private: for static web content you use `sites`.

    The notifications reference queues, topics and functions **by key**, not by ARN.
  EOT
  type = map(object({
    versioning_enabled = optional(bool, true)
    kms_key_arn        = optional(string)
    force_destroy      = optional(bool, false)
    object_ownership   = optional(string, "BucketOwnerEnforced")

    cors_rules = optional(list(object({
      id              = optional(string)
      allowed_methods = list(string)
      allowed_origins = list(string)
      allowed_headers = optional(list(string))
      expose_headers  = optional(list(string))
      max_age_seconds = optional(number)
    })), [])

    lifecycle_rules = optional(list(object({
      id      = string
      enabled = optional(bool, true)
      filter = optional(object({
        prefix                   = optional(string)
        tags                     = optional(map(string))
        object_size_greater_than = optional(number)
        object_size_less_than    = optional(number)
      }))
      expiration = optional(object({
        days                         = optional(number)
        date                         = optional(string)
        expired_object_delete_marker = optional(bool)
      }))
      noncurrent_version_expiration = optional(object({
        noncurrent_days           = number
        newer_noncurrent_versions = optional(number)
      }))
      transition = optional(list(object({
        days          = number
        storage_class = string
      })), [])
      noncurrent_version_transition = optional(list(object({
        noncurrent_days = number
        storage_class   = string
      })), [])
      abort_incomplete_multipart_upload_days = optional(number)
    })), [])

    notifications = optional(object({
      queues = optional(map(object({
        queue         = string
        events        = list(string)
        filter_prefix = optional(string)
        filter_suffix = optional(string)
      })), {})
      topics = optional(map(object({
        topic         = string
        events        = list(string)
        filter_prefix = optional(string)
        filter_suffix = optional(string)
      })), {})
      functions = optional(map(object({
        function      = string
        events        = list(string)
        filter_prefix = optional(string)
        filter_suffix = optional(string)
      })), {})
    }), {})

    logging = optional(object({
      target_bucket = string
      target_prefix = optional(string)
    }))

    tags = optional(map(string), {})
  }))
  default = {}
}

variable "secrets" {
  description = "Secrets in Secrets Manager. Created empty: the value is written by somebody else."
  type = map(object({
    description             = optional(string)
    kms_key_id              = optional(string)
    recovery_window_in_days = optional(number, 30)
    initial_value           = optional(string)
    ignore_value_changes    = optional(bool, true)
    tags                    = optional(map(string), {})
  }))
  default = {}
}

# ------------------------------------------------------------------------------
# Messaging
# ------------------------------------------------------------------------------

variable "topics" {
  description = <<-EOT
    SNS topics.

    `to_queues` declares the fan-out towards the queues **from the topic side**, which is the
    natural form to read. The module inverts it and passes it to `modules/queue`, where fan-in
    from several topics can converge into a single policy document: SQS allows a single `Policy`
    attribute per queue, and this inversion is precisely the work that belongs to the
    composition.

        topics = {
          operations = { to_queues = { events = {} } }
          audit      = { to_queues = { events = { filter_policy = jsonencode({ severity = ["critical"] }) } } }
        }
  EOT
  type = map(object({
    display_name = optional(string)

    fifo = optional(object({
      enabled                     = optional(bool, false)
      content_based_deduplication = optional(bool, false)
      throughput_scope            = optional(string)
    }), {})

    kms_key_id = optional(string)

    to_queues = optional(map(object({
      filter_policy        = optional(string)
      filter_policy_scope  = optional(string, "MessageAttributes")
      raw_message_delivery = optional(bool, false)
    })), {})

    subscriptions = optional(map(object({
      protocol              = string
      endpoint              = string
      filter_policy         = optional(string)
      filter_policy_scope   = optional(string, "MessageAttributes")
      raw_message_delivery  = optional(bool)
      subscription_role_arn = optional(string)
    })), {})

    allow_publish_from = optional(list(object({
      service        = string
      source_arn     = optional(string)
      source_account = optional(string)
    })), [])

    tags = optional(map(string), {})
  }))
  default = {}
}

variable "queues" {
  description = <<-EOT
    SQS queues. Subscriptions from topics are declared on `topics[*].to_queues`.

    `allow_send_from_buckets` lists the keys of the buckets authorized to write: the module
    resolves the ARN statically from the name, because the bucket depends on the queue for the
    notification and a reverse reference would be a cycle.
  EOT
  type = map(object({
    fifo = optional(object({
      enabled                     = optional(bool, false)
      content_based_deduplication = optional(bool, false)
      deduplication_scope         = optional(string)
      throughput_limit            = optional(string)
    }), {})

    visibility_timeout_seconds = optional(number, 30)
    message_retention_seconds  = optional(number, 345600)
    receive_wait_time_seconds  = optional(number, 20)
    delay_seconds              = optional(number, 0)
    kms_key_id                 = optional(string)

    dlq = optional(object({
      enabled                    = optional(bool, true)
      max_receive_count          = optional(number, 5)
      message_retention_seconds  = optional(number, 1209600)
      visibility_timeout_seconds = optional(number)
    }), {})

    allow_send_from_buckets = optional(list(string), [])

    allow_send_from = optional(list(object({
      service        = string
      source_arn     = optional(string)
      source_account = optional(string)
    })), [])

    tags = optional(map(string), {})
  }))
  default = {}
}

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------

variable "security_groups" {
  description = "Security groups. The functions reference them by key in `vpc.security_group_keys`."
  type = map(object({
    description = optional(string)
    vpc_id      = optional(string)
    vpc_name    = optional(string)

    ingress_cidr_rules = optional(list(object({
      from_port   = number
      to_port     = number
      protocol    = optional(string, "tcp")
      cidr_blocks = string
      description = optional(string)
    })), [])

    ingress_source_sg_rules = optional(list(object({
      from_port                = number
      to_port                  = number
      protocol                 = optional(string, "tcp")
      source_security_group_id = string
      description              = optional(string)
    })), [])

    ingress_self_rules = optional(list(object({
      from_port   = number
      to_port     = number
      protocol    = optional(string, "tcp")
      description = optional(string)
    })), [])

    egress_cidr_rules = optional(list(object({
      from_port   = number
      to_port     = number
      protocol    = optional(string, "tcp")
      cidr_blocks = string
      description = optional(string)
    })), [])

    egress_source_sg_rules = optional(list(object({
      from_port                = number
      to_port                  = number
      protocol                 = optional(string, "tcp")
      source_security_group_id = string
      description              = optional(string)
    })), [])

    egress_self_rules = optional(list(object({
      from_port   = number
      to_port     = number
      protocol    = optional(string, "tcp")
      description = optional(string)
    })), [])

    allow_all_egress = optional(bool, true)
    tags             = optional(map(string), {})
  }))
  default = {}
}

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------

variable "functions" {
  description = <<-EOT
    Lambda functions.

    `env` holds literal values, `env_from` references to resources by key, `grants` the
    permissions by intent in the form `<type>/<name> = [capability]`. The environment
    variable's name has no effect whatsoever on the resolution.

        functions = {
          files = {
            env      = { LOG_LEVEL = "info" }
            env_from = { DOCS = { bucket = "documents" }, DB = { secret = "mongodb" } }
            grants   = { "bucket/documents" = ["read", "write"], "secret/mongodb" = ["read"] }
          }
        }
  EOT
  type = map(object({
    description = optional(string)

    image = optional(string)
    package = optional(object({
      local_path = optional(string)
      s3_bucket  = optional(string)
      s3_key     = optional(string)
    }))
    ignore_code_changes = optional(bool, true)

    runtime       = optional(string, "provided.al2023")
    handler       = optional(string, "bootstrap")
    architectures = optional(list(string), ["arm64"])
    layers        = optional(list(string), [])

    memory_size                    = optional(number, 128)
    timeout                        = optional(number, 3)
    ephemeral_storage_size         = optional(number)
    reserved_concurrent_executions = optional(number, -1)

    vpc = optional(object({
      subnet_ids          = list(string)
      security_group_keys = optional(list(string), [])
      security_group_ids  = optional(list(string), [])
    }))

    env = optional(map(string), {})

    env_from = optional(map(object({
      bucket = optional(string)
      table  = optional(string)
      topic  = optional(string)
      queue  = optional(string)
      secret = optional(string)
      attr   = optional(string)
    })), {})

    grants = optional(map(list(string)), {})

    extra_policy_statements = optional(list(object({
      sid       = optional(string)
      effect    = optional(string, "Allow")
      actions   = list(string)
      resources = list(string)
      condition = optional(list(object({
        test     = string
        variable = string
        values   = list(string)
      })), [])
    })), [])

    managed_policy_arns = optional(list(string), [])

    event_sources = optional(map(object({
      queue                              = optional(string)
      event_source_arn                   = optional(string)
      enabled                            = optional(bool, true)
      batch_size                         = optional(number)
      maximum_batching_window_in_seconds = optional(number)
      function_response_types            = optional(list(string), [])
      maximum_concurrency                = optional(number)
      filter_patterns                    = optional(list(string), [])
    })), {})

    async = optional(object({
      enabled                      = optional(bool, true)
      maximum_retry_attempts       = optional(number, 2)
      maximum_event_age_in_seconds = optional(number)
      on_failure_queue             = optional(string)
      on_failure_topic             = optional(string)
    }), {})

    observability = optional(object({
      log_retention_days = optional(number, 7)
      log_kms_key_id     = optional(string)
      log_format         = optional(string, "JSON")
      log_level          = optional(string)
      system_log_level   = optional(string)
      tracing            = optional(bool, true)
      alarms = optional(object({
        enabled                  = optional(bool, true)
        error_threshold          = optional(number, 1)
        error_period             = optional(number, 300)
        throttle_threshold       = optional(number, 1)
        throttle_period          = optional(number, 300)
        duration_threshold_ratio = optional(number, 0.8)
        duration_period          = optional(number, 300)
      }), {})
    }), {})

    tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for f in values(var.functions) : (f.image != null) != (f.package != null)
    ])
    error_message = format(
      "Every function must state either `image` or `package`, not both and not neither. Non-conforming: %s.",
      join(", ", [for k, f in var.functions : k if(f.image != null) == (f.package != null)]),
    )
  }
}

# ------------------------------------------------------------------------------
# External surface
# ------------------------------------------------------------------------------

variable "http_apis" {
  description = "HTTP API Gateways. The routes reference the functions by key."
  type = map(object({
    description = optional(string)
    stage_name  = optional(string, "$default")

    routes = optional(map(object({
      function               = string
      authorizer             = optional(string)
      authorization_scopes   = optional(list(string), [])
      payload_format_version = optional(string, "2.0")
      timeout_milliseconds   = optional(number)
      throttling_burst_limit = optional(number)
      throttling_rate_limit  = optional(number)
    })), {})

    authorizers = optional(map(object({
      type                    = optional(string, "lambda")
      function                = optional(string)
      identity_sources        = optional(list(string), ["$request.header.Authorization"])
      result_ttl_in_seconds   = optional(number, 0)
      enable_simple_responses = optional(bool, true)
      jwt = optional(object({
        issuer   = string
        audience = list(string)
      }))
    })), {})

    cors = optional(object({
      allow_origins     = optional(list(string), [])
      allow_methods     = optional(list(string), [])
      allow_headers     = optional(list(string), ["content-type", "authorization", "x-amz-date", "x-api-key", "x-amz-security-token"])
      expose_headers    = optional(list(string), [])
      allow_credentials = optional(bool, false)
      max_age           = optional(number)
    }))

    domain = optional(object({
      name            = string
      certificate_arn = optional(string)
      zone_name       = optional(string)
      create_records  = optional(bool, true)
    }))

    throttling = optional(object({
      burst_limit = optional(number, 500)
      rate_limit  = optional(number, 1000)
    }), {})

    access_logs = optional(object({
      enabled         = optional(bool, true)
      retention_days  = optional(number, 30)
      kms_key_id      = optional(string)
      destination_arn = optional(string)
    }), {})

    disable_default_endpoint = optional(bool, false)

    alarms = optional(object({
      enabled                = optional(bool, true)
      server_error_threshold = optional(number, 1)
      server_error_period    = optional(number, 300)
      latency_threshold_ms   = optional(number, 3000)
      latency_period         = optional(number, 300)
    }), {})

    tags = optional(map(string), {})
  }))
  default = {}
}

variable "sites" {
  description = "Static sites: a private bucket plus CloudFront with Origin Access Control."
  type = map(object({
    comment                    = optional(string)
    aliases                    = optional(list(string), [])
    certificate_arn            = optional(string)
    web_acl_arn                = optional(string)
    zone_id                    = optional(string)
    spa                        = optional(bool, false)
    default_root_object        = optional(string, "index.html")
    price_class                = optional(string, "PriceClass_100")
    cache_policy_id            = optional(string, "658327ea-f89d-4fab-a63d-7e88639e58f6")
    response_headers_policy_id = optional(string, "67f7725c-6f97-4210-82d7-5512b31e9d03")
    allowed_methods            = optional(list(string), ["GET", "HEAD", "OPTIONS"])
    bucket_force_destroy       = optional(bool, false)
    wait_for_deployment        = optional(bool, false)
    tags                       = optional(map(string), {})
  }))
  default = {}
}

variable "registries" {
  description = "ECR repositories for the container functions."
  type = map(object({
    immutable_tags        = optional(bool, true)
    mutable_tag_patterns  = optional(list(string), ["latest", "dev-*"])
    scan_on_push          = optional(bool, true)
    kms_key_arn           = optional(string)
    force_delete          = optional(bool, false)
    untagged_expire_days  = optional(number, 1)
    keep_tagged_images    = optional(number, 30)
    retained_tag_prefixes = optional(list(string), ["v"])
    read_access_arns      = optional(list(string), [])

    # Keys in `functions`: the permission on the repository's policy is what container Lambdas
    # need, and without it the function's creation fails with an error that talks about an
    # image not found.
    lambda_read_access_functions = optional(list(string), [])

    tags = optional(map(string), {})
  }))
  default = {}
}

variable "schedules" {
  description = "EventBridge Scheduler schedules. The target references a function or a queue by key."
  type = map(object({
    description = optional(string)
    expression  = string
    timezone    = optional(string, "UTC")
    enabled     = optional(bool, true)
    group_name  = optional(string)

    target_function          = optional(string)
    target_queue             = optional(string)
    target_state_machine_arn = optional(string)
    input                    = optional(string)
    message_group_id         = optional(string)

    dead_letter_queue         = optional(string)
    allow_missing_dead_letter = optional(bool, false)

    retry = optional(object({
      maximum_retry_attempts       = optional(number, 3)
      maximum_event_age_in_seconds = optional(number, 3600)
    }), {})

    flexible_time_window_minutes = optional(number)
    start_date                   = optional(string)
    end_date                     = optional(string)

    tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for s in values(var.schedules) : length([
        for v in [s.target_function, s.target_queue, s.target_state_machine_arn] : v if v != null
      ]) == 1
    ])
    error_message = "Every schedule must state exactly one of `target_function`, `target_queue` and `target_state_machine_arn`."
  }
}

# ------------------------------------------------------------------------------
# Observability
# ------------------------------------------------------------------------------

variable "observability" {
  description = <<-EOT
    Alarm topic, dashboard and log forwarding.

    The topic is created **before** the primitives and its ARN is wired automatically into
    everyone's `alarms.actions`: there is no way to create an alarm that notifies nobody.
  EOT
  type = object({
    enabled = optional(bool, true)

    alarm_topic_kms_key_id = optional(string)
    alarm_subscriptions = optional(map(object({
      protocol = string
      endpoint = string
    })), {})

    dashboard_enabled = optional(bool, true)

    log_shipping = optional(object({
      destination_arn = string
      role_arn        = optional(string)
      filter_pattern  = optional(string, "")
    }))

    composite_alarm_enabled = optional(bool, false)
  })
  default = {}
}
