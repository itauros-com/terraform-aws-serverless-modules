variable "name" {
  description = "The queue's name, without the `.fifo` suffix (the module adds it). If `prefix` is set the final name is `<prefix>-<name>`."
  type        = string

  validation {
    condition     = !endswith(var.name, ".fifo")
    error_message = "Do not add `.fifo` to the name: the module handles it based on `fifo.enabled`."
  }
}

variable "prefix" {
  description = "Naming prefix, typically `<project>-<environment>`."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}

variable "fifo" {
  description = <<-EOT
    FIFO configuration. With `enabled = true` the queue's name receives the `.fifo`
    suffix and the DLQ becomes FIFO too, as AWS requires.
  EOT
  type = object({
    enabled                     = optional(bool, false)
    content_based_deduplication = optional(bool, false)
    deduplication_scope         = optional(string)
    throughput_limit            = optional(string)
  })
  default = {}

  validation {
    condition = var.fifo.deduplication_scope == null || contains(
      ["messageGroup", "queue"], coalesce(var.fifo.deduplication_scope, "")
    )
    error_message = "fifo.deduplication_scope must be 'messageGroup' or 'queue'."
  }

  validation {
    condition = var.fifo.throughput_limit == null || contains(
      ["perQueue", "perMessageGroupId"], coalesce(var.fifo.throughput_limit, "")
    )
    error_message = "fifo.throughput_limit must be 'perQueue' or 'perMessageGroupId'."
  }
}

variable "visibility_timeout_seconds" {
  description = <<-EOT
    How long a message being processed stays invisible.

    It must be set to at least the timeout of the consuming function, otherwise the
    message becomes visible again while it is still being worked on and gets processed
    twice. A rule of thumb is six times the function's timeout.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.visibility_timeout_seconds >= 0 && var.visibility_timeout_seconds <= 43200
    error_message = "visibility_timeout_seconds must be between 0 and 43200 (12 hours)."
  }
}

variable "message_retention_seconds" {
  description = "How long an unconsumed message stays in the queue. AWS default: 4 days."
  type        = number
  default     = 345600

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600
    error_message = "message_retention_seconds must be between 60 and 1209600 (14 days)."
  }
}

variable "receive_wait_time_seconds" {
  description = <<-EOT
    Long polling. This module's default is 20 seconds, not AWS's zero: with short
    polling you pay for many more empty requests and add pointless latency to delivery.
  EOT
  type        = number
  default     = 20

  validation {
    condition     = var.receive_wait_time_seconds >= 0 && var.receive_wait_time_seconds <= 20
    error_message = "receive_wait_time_seconds must be between 0 and 20."
  }
}

variable "delay_seconds" {
  description = "Delivery delay applied to every message."
  type        = number
  default     = 0
}

variable "max_message_size" {
  description = "Maximum message size in bytes."
  type        = number
  default     = 262144
}

variable "encryption" {
  description = <<-EOT
    Encryption at rest. Enabled by default with the SQS-managed key: a queue in the
    clear is AWS's default, not a choice.

    Setting `kms_key_id` switches to a CMK. In that case remember to pass the same key
    in the consumers' resource registry, so that the KMS permissions are generated
    automatically from the grants.
  EOT
  type = object({
    managed                           = optional(bool, true)
    kms_key_id                        = optional(string)
    kms_data_key_reuse_period_seconds = optional(number)
  })
  default = {}
}

variable "dlq" {
  description = <<-EOT
    Dead letter queue.

    Enabled by default: without a DLQ a message that fails repeatedly stays in the
    queue until it expires and then disappears, with nobody noticing.
    `max_receive_count` is the part the previous wiring did not expose at all — without
    it the redrive is not configured and the DLQ stays empty forever.

    The DLQ's retention is 14 days by default: if a message ended up there, you need
    the time to notice and to reprocess it.
  EOT
  type = object({
    enabled                    = optional(bool, true)
    max_receive_count          = optional(number, 5)
    message_retention_seconds  = optional(number, 1209600)
    visibility_timeout_seconds = optional(number)
  })
  default = {}

  validation {
    condition     = var.dlq.max_receive_count >= 1 && var.dlq.max_receive_count <= 1000
    error_message = "dlq.max_receive_count must be between 1 and 1000."
  }
}

variable "subscriptions" {
  description = <<-EOT
    SNS topics that publish onto this queue.

    The subscriptions are declared **on the queue side** and not on the topic side for
    a precise reason: SQS allows a single `Policy` attribute per queue, so with several
    topics publishing onto the same queue you need one document with one statement per
    topic. Declared on the topic side, every topic would try to write its own policy
    and only the last one would survive, silently.

        subscriptions = {
          events = { topic_arn = module.events.arn }
          audit  = { topic_arn = module.audit.arn, filter_policy = jsonencode({ type = ["critical"] }) }
        }
  EOT
  type = map(object({
    topic_arn            = string
    filter_policy        = optional(string)
    filter_policy_scope  = optional(string, "MessageAttributes")
    raw_message_delivery = optional(bool, false)
  }))
  default = {}

  validation {
    condition = alltrue([
      for s in values(var.subscriptions) : contains(["MessageAttributes", "MessageBody"], s.filter_policy_scope)
    ])
    error_message = "filter_policy_scope must be 'MessageAttributes' or 'MessageBody'."
  }

  validation {
    condition     = alltrue([for k in keys(var.subscriptions) : can(regex("^[0-9A-Za-z_-]+$", k))])
    error_message = "The subscriptions keys end up in the policy's Sids: use only letters, digits, '-' and '_'."
  }
}

variable "allow_send_from" {
  description = <<-EOT
    AWS services authorized to send messages to this queue, beyond the topics declared
    in `subscriptions`. Needed for S3 notifications, EventBridge events and the
    on-failure destinations of other services.

    `source_arn` must be passed as a **string**, not as a reference to the resource: a
    bucket notifying a queue needs the queue's ARN, and the queue needs the bucket's
    ARN. Referring to the resource would create a cycle between the two modules. S3
    ARNs are deterministic from the name, so the string is safe.

        allow_send_from = [
          { service = "s3", source_arn = "arn:aws:s3:::acme-prod-documents" },
          { service = "events", source_account = "111122223333" },
        ]
  EOT
  type = list(object({
    service        = string
    source_arn     = optional(string)
    source_account = optional(string)
  }))
  default = []

  validation {
    condition = alltrue([
      for a in var.allow_send_from : (a.source_arn != null) != (a.source_account != null)
    ])
    error_message = "Every allow_send_from entry must state either `source_arn` or `source_account`, not both and not neither: without a condition the policy would authorize any resource of that service, in any account."
  }

  # Dots stay allowed because some principals use them in the short name
  # (`delivery.logs`), but the full suffix must be rejected: the module adds it itself
  # and passing it would produce `s3.amazonaws.com.amazonaws.com`.
  validation {
    condition = alltrue([
      for a in var.allow_send_from :
      can(regex("^[a-z0-9.-]+$", a.service)) && !endswith(a.service, ".amazonaws.com")
    ])
    error_message = "service must be the service's short name (e.g. 's3', 'events', 'sns'), without '.amazonaws.com'."
  }
}

variable "extra_policy_statements" {
  description = "Additional statements for the queue's policy, in the format the upstream module accepts."
  type = map(object({
    sid           = optional(string)
    effect        = optional(string, "Allow")
    actions       = optional(list(string))
    not_actions   = optional(list(string))
    resources     = optional(list(string))
    not_resources = optional(list(string))
    principals = optional(list(object({
      type        = string
      identifiers = list(string)
    })))
    condition = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })))
  }))
  default = {}
}

variable "alarms" {
  description = <<-EOT
    Alarms on the queue and the DLQ.

    `age_threshold_seconds` watches the age of the oldest message: it is the signal
    that tells you whether the consumers are keeping up, far more useful than the
    queue's depth, which grows for a mere traffic spike too.

    On the DLQ the threshold is **one** message: any message in a DLQ is an incident,
    not a metric to keep an eye on.
  EOT
  type = object({
    enabled               = optional(bool, true)
    actions               = optional(list(string), [])
    ok_actions            = optional(list(string), [])
    age_threshold_seconds = optional(number, 300)
    age_period            = optional(number, 300)
    dlq_threshold         = optional(number, 1)
    dlq_period            = optional(number, 300)
  })
  default = {}
}
