variable "name" {
  description = "The function's name. If `prefix` is set the final name is `<prefix>-<name>`."
  type        = string
}

variable "prefix" {
  description = "Naming prefix, typically `<project>-<environment>`. Left null, `name` is used as is."
  type        = string
  default     = null
}

variable "description" {
  description = "The function's description."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# Code
# ------------------------------------------------------------------------------

variable "image_uri" {
  description = "URI of the container image in ECR. Mutually exclusive with `package`."
  type        = string
  default     = null
}

variable "package" {
  description = <<-EOT
    The function's zip package. Mutually exclusive with `image_uri`.

    `local_path` points at an already built zip; `s3_bucket`/`s3_key` at a zip on S3.
    The module does not build packages: the build is CI's responsibility.
  EOT
  type = object({
    local_path = optional(string)
    s3_bucket  = optional(string)
    s3_key     = optional(string)
  })
  default = null

  validation {
    condition = var.package == null || (
      (var.package.local_path != null) != (var.package.s3_bucket != null && var.package.s3_key != null)
    )
    error_message = "package requires either `local_path` or the `s3_bucket` + `s3_key` pair, not both."
  }
}

variable "ignore_code_changes" {
  description = <<-EOT
    Ignore the code hash, so that an out-of-band deploy (CI running
    `update-function-code`) does not produce a diff on every plan.

    The `true` default reflects the current deploy model. Moving to images with an
    immutable tag passed by CI, it is worth setting this to `false`, so that Terraform
    goes back to being the truth about the deployed code and a rollback is a revert.
  EOT
  type        = bool
  default     = true
}

variable "runtime" {
  description = "Lambda runtime. Ignored for container functions."
  type        = string
  default     = "provided.al2023"
}

variable "handler" {
  description = "Handler. For the `provided.*` runtimes it is the executable's name."
  type        = string
  default     = "bootstrap"
}

variable "architectures" {
  description = "Architecture. arm64 costs less for the same performance on typical workloads."
  type        = list(string)
  default     = ["arm64"]

  validation {
    condition     = length(var.architectures) == 1 && contains(["arm64", "x86_64"], var.architectures[0])
    error_message = "architectures must contain exactly one of 'arm64' and 'x86_64'."
  }
}

variable "layers" {
  description = "ARNs of the layers to attach."
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------------------------
# Runtime and capacity
# ------------------------------------------------------------------------------

variable "memory_size" {
  description = "Memory in MB. It also determines the CPU share."
  type        = number
  default     = 128

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "memory_size must be between 128 and 10240 MB."
  }
}

variable "timeout" {
  description = "Timeout in seconds. Behind an HTTP API Gateway the useful limit is 29s; beyond that the gateway answers 504."
  type        = number
  default     = 3

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900
    error_message = "timeout must be between 1 and 900 seconds."
  }
}

variable "ephemeral_storage_size" {
  description = "Size of /tmp in MB. Null leaves the AWS default of 512."
  type        = number
  default     = null
}

variable "reserved_concurrent_executions" {
  description = "Reserved concurrency. -1 means no reservation (uses the account pool)."
  type        = number
  default     = -1
}

variable "vpc" {
  description = <<-EOT
    VPC configuration. When it is set the module attaches the necessary network
    permissions on its own; when it is null it does not attach them at all.

    This conditionality is deliberate: giving ENI permissions to a function that is
    not in a VPC is a pointless widening of its surface.
  EOT
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null

  validation {
    condition     = var.vpc == null || length(var.vpc.subnet_ids) > 0
    error_message = "vpc.subnet_ids cannot be empty."
  }
}

# ------------------------------------------------------------------------------
# Configuration and references
# ------------------------------------------------------------------------------

variable "env" {
  description = "Environment variables with a literal value."
  type        = map(string)
  default     = {}
}

variable "env_from" {
  description = <<-EOT
    Environment variables whose value is a reference to a resource in `resources`,
    resolved by the module.

    You state the resource's type and key; `attr` picks which attribute to inject and
    has a sensible default per type: `name` for buckets, tables and secrets, `arn` for
    topics, `url` for queues.

        env_from = {
          DOCS_BUCKET = { bucket = "documents" }
          JOBS_QUEUE  = { queue  = "emails" }
          EVENTS_ARN  = { topic  = "operations" }
          MONGO_URI   = { secret = "mongodb" }
        }

    The environment variable's name has no effect whatsoever on the resolution: it is
    just a name. A reference to a resource that does not exist makes the plan fail.
  EOT
  type = map(object({
    bucket = optional(string)
    table  = optional(string)
    topic  = optional(string)
    queue  = optional(string)
    secret = optional(string)
    attr   = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, r in var.env_from :
      length([for v in [r.bucket, r.table, r.topic, r.queue, r.secret] : v if v != null]) == 1
    ])
    error_message = format(
      "Every env_from entry must state exactly one resource type among bucket, table, topic, queue, secret. Non-conforming entries: %s.",
      join(", ", [
        for k, r in var.env_from : k
        if length([for v in [r.bucket, r.table, r.topic, r.queue, r.secret] : v if v != null]) != 1
      ])
    )
  }

  validation {
    condition = alltrue([
      for r in values(var.env_from) : r.attr == null || contains(["name", "arn", "url"], r.attr)
    ])
    error_message = "attr must be 'name', 'arn' or 'url'."
  }

  validation {
    condition = alltrue([
      for r in values(var.env_from) :
      (r.bucket == null || contains(keys(var.resources.buckets), coalesce(r.bucket, ""))) &&
      (r.table == null || contains(keys(var.resources.tables), coalesce(r.table, ""))) &&
      (r.topic == null || contains(keys(var.resources.topics), coalesce(r.topic, ""))) &&
      (r.queue == null || contains(keys(var.resources.queues), coalesce(r.queue, ""))) &&
      (r.secret == null || contains(keys(var.resources.secrets), coalesce(r.secret, "")))
    ])
    error_message = format(
      "env_from references resources that are not in `resources`: %s. Available registry: buckets [%s], tables [%s], topics [%s], queues [%s], secrets [%s].",
      join(", ", [
        for k, r in var.env_from : format("%s → %s", k, coalesce(r.bucket, r.table, r.topic, r.queue, r.secret, "?"))
        if !(
          (r.bucket == null || contains(keys(var.resources.buckets), coalesce(r.bucket, ""))) &&
          (r.table == null || contains(keys(var.resources.tables), coalesce(r.table, ""))) &&
          (r.topic == null || contains(keys(var.resources.topics), coalesce(r.topic, ""))) &&
          (r.queue == null || contains(keys(var.resources.queues), coalesce(r.queue, ""))) &&
          (r.secret == null || contains(keys(var.resources.secrets), coalesce(r.secret, "")))
        )
      ]),
      join(", ", keys(var.resources.buckets)),
      join(", ", keys(var.resources.tables)),
      join(", ", keys(var.resources.topics)),
      join(", ", keys(var.resources.queues)),
      join(", ", keys(var.resources.secrets)),
    )
  }
}

variable "resources" {
  description = <<-EOT
    The registry of resources referenceable from `env_from`, `grants` and
    `event_sources`. The same shape `modules/grants` accepts: build it once and pass
    it to both.
  EOT
  type = object({
    buckets = optional(map(object({
      arn         = string
      name        = optional(string)
      url         = optional(string)
      kms_key_arn = optional(string)
    })), {})
    tables = optional(map(object({
      arn         = string
      name        = optional(string)
      url         = optional(string)
      kms_key_arn = optional(string)
    })), {})
    topics = optional(map(object({
      arn         = string
      name        = optional(string)
      url         = optional(string)
      kms_key_arn = optional(string)
    })), {})
    queues = optional(map(object({
      arn         = string
      name        = optional(string)
      url         = optional(string)
      kms_key_arn = optional(string)
    })), {})
    secrets = optional(map(object({
      arn         = string
      name        = optional(string)
      url         = optional(string)
      kms_key_arn = optional(string)
    })), {})
  })
  default = {}
}

# ------------------------------------------------------------------------------
# IAM
# ------------------------------------------------------------------------------

variable "grants" {
  description = <<-EOT
    Permissions declared by intent, in the form `<type>/<name> = [capability]`. They
    are translated into policies by `modules/grants`, which documents the table.

        grants = {
          "bucket/documents" = ["read", "write"]
          "table/tenants"    = ["read", "scan"]
          "queue/emails"     = ["consume"]
        }

    Declaring an `event_sources` entry on a queue **requires** the `consume`
    capability on that queue: the module verifies the two sides agree and stops the
    plan otherwise. It does not create the mapping as a side effect of the permission
    — `consume` alone is legitimate, and is what you want when you poll yourself.
  EOT
  type        = map(list(string))
  default     = {}
}

variable "extra_policy_statements" {
  description = "Literal IAM statements, for services outside the capability table (SES, Bedrock, …)."
  type = list(object({
    sid       = optional(string)
    effect    = optional(string, "Allow")
    actions   = list(string)
    resources = list(string)
    condition = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
  }))
  default = []
}

variable "managed_policy_arns" {
  description = "ARNs of managed policies to attach to the role. An escape hatch: prefer `grants`."
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------------------------
# Event sources and asynchronous invocation
# ------------------------------------------------------------------------------

variable "event_sources" {
  description = <<-EOT
    Event source mappings. `queue` is a key in `resources.queues`; alternatively you
    pass an explicit `event_source_arn`.

    `function_response_types = ["ReportBatchItemFailures"]` enables partial failure
    reporting, so that a single problematic message does not make the whole batch be
    retried. It is not the default because it requires the handler to return the
    expected structure: a non-conforming handler would make the entire batch be
    considered failed.
  EOT
  type = map(object({
    queue                              = optional(string)
    event_source_arn                   = optional(string)
    enabled                            = optional(bool, true)
    batch_size                         = optional(number)
    maximum_batching_window_in_seconds = optional(number)
    function_response_types            = optional(list(string), [])
    maximum_concurrency                = optional(number)
    filter_patterns                    = optional(list(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, s in var.event_sources :
      (s.queue != null) != (s.event_source_arn != null)
    ])
    error_message = "Every event source must state either `queue` or `event_source_arn`, not both and not neither."
  }

  validation {
    condition = alltrue([
      for s in var.event_sources :
      s.queue == null || contains(keys(var.resources.queues), coalesce(s.queue, ""))
    ])
    error_message = format(
      "event_sources references queues that are not in `resources.queues`: %s.",
      join(", ", [for k, s in var.event_sources : k if s.queue != null && !contains(keys(var.resources.queues), coalesce(s.queue, ""))]),
    )
  }

  validation {
    condition = alltrue([
      for s in var.event_sources :
      alltrue([for t in s.function_response_types : t == "ReportBatchItemFailures"])
    ])
    error_message = "function_response_types only accepts 'ReportBatchItemFailures'."
  }

  # An event source mapping on a queue without the `consume` capability is broken by
  # construction: the mapping exists, has no permissions and receives nothing. The two
  # sides live in different places in the configuration and are edited at different
  # times, so the coherence must be checked here and not at runtime.
  validation {
    condition = alltrue([
      for k, s in var.event_sources : s.queue == null ? true : contains(
        [for key, caps in var.grants : split("/", key)[1] if startswith(key, "queue/") && contains(caps, "consume")],
        coalesce(s.queue, "")
      )
    ])
    error_message = format(
      "Event source mapping on queues without the 'consume' capability: %s. Add `\"queue/<name>\" = [\"consume\"]` to grants, otherwise the mapping receives no messages.",
      join(", ", [
        for k, s in var.event_sources : format("%s (queue '%s')", k, s.queue)
        if s.queue != null && !contains(
          [for key, caps in var.grants : split("/", key)[1] if startswith(key, "queue/") && contains(caps, "consume")],
          coalesce(s.queue, "")
        )
      ]),
    )
  }
}

variable "async" {
  description = <<-EOT
    Behaviour of asynchronous invocations.

    `on_failure` is the destination for events that have exhausted their attempts.
    Without a destination a failed asynchronous event **disappears without a trace**,
    which is why this configuration is enabled by default.

    `enabled = false` turns it off entirely: this is for a migration at parity of
    resources, where any addition would produce a diff.
  EOT
  type = object({
    enabled                      = optional(bool, true)
    maximum_retry_attempts       = optional(number, 2)
    maximum_event_age_in_seconds = optional(number)
    on_failure = optional(object({
      queue = optional(string)
      topic = optional(string)
      arn   = optional(string)
    }))
  })
  default = {}

  validation {
    condition = var.async.on_failure == null || length([
      for v in [var.async.on_failure.queue, var.async.on_failure.topic, var.async.on_failure.arn] : v if v != null
    ]) == 1
    error_message = "async.on_failure must state exactly one of `queue`, `topic` and `arn`."
  }

  validation {
    condition     = var.async.maximum_retry_attempts >= 0 && var.async.maximum_retry_attempts <= 2
    error_message = "async.maximum_retry_attempts must be between 0 and 2."
  }
}

# ------------------------------------------------------------------------------
# Observability
# ------------------------------------------------------------------------------

variable "observability" {
  description = <<-EOT
    Logs, tracing and alarms. Enabled by default: a function you do not observe is a
    function you find out is broken from your users.

    `alarms.enabled = false` and `tracing = false` are for a migration at parity of
    resources, where any addition would produce a diff.

    `duration_threshold_ratio` is the fraction of the timeout beyond which the p99
    duration trips the alarm: 0.8 warns before the function starts being killed by the
    timeout, not after.
  EOT
  type = object({
    log_retention_days = optional(number, 7)
    log_kms_key_id     = optional(string)
    log_format         = optional(string, "JSON")
    log_level          = optional(string)
    system_log_level   = optional(string)
    tracing            = optional(bool, true)
    alarms = optional(object({
      enabled                  = optional(bool, true)
      actions                  = optional(list(string), [])
      ok_actions               = optional(list(string), [])
      error_threshold          = optional(number, 1)
      error_period             = optional(number, 300)
      throttle_threshold       = optional(number, 1)
      throttle_period          = optional(number, 300)
      duration_threshold_ratio = optional(number, 0.8)
      duration_period          = optional(number, 300)
    }), {})
  })
  default = {}

  validation {
    condition     = contains(["JSON", "Text"], var.observability.log_format)
    error_message = "observability.log_format must be 'JSON' or 'Text'."
  }

  validation {
    condition = (
      var.observability.alarms.duration_threshold_ratio > 0 &&
      var.observability.alarms.duration_threshold_ratio <= 1
    )
    error_message = "observability.alarms.duration_threshold_ratio must be between 0 (exclusive) and 1."
  }

  validation {
    condition = var.observability.log_level == null || contains(
      ["TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL"], coalesce(var.observability.log_level, "")
    )
    error_message = "observability.log_level must be one of TRACE, DEBUG, INFO, WARN, ERROR, FATAL."
  }
}

# ------------------------------------------------------------------------------
# Triggers
# ------------------------------------------------------------------------------

variable "allowed_triggers" {
  description = <<-EOT
    Invocation permissions (`aws_lambda_permission`) for the services that call this
    function: API Gateway, EventBridge, SNS.

    Normally `modules/app` populates them from the wiring graph; here they stay
    exposed for à-la-carte usage.
  EOT
  type = map(object({
    principal     = string
    source_arn    = optional(string)
    action        = optional(string, "lambda:InvokeFunction")
    statement_id  = optional(string)
    principal_org = optional(string)
  }))
  default = {}
}
