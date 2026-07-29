variable "name" {
  description = "The topic's name, without the `.fifo` suffix (the module adds it). If `prefix` is set the final name is `<prefix>-<name>`."
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

variable "display_name" {
  description = "Display name, used as the sender in email and SMS notifications."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}

variable "fifo" {
  description = "FIFO configuration. With `enabled = true` the name receives the `.fifo` suffix."
  type = object({
    enabled                     = optional(bool, false)
    content_based_deduplication = optional(bool, false)
    throughput_scope            = optional(string)
  })
  default = {}

  validation {
    condition = var.fifo.throughput_scope == null || contains(
      ["Topic", "MessageGroup"], coalesce(var.fifo.throughput_scope, "")
    )
    error_message = "fifo.throughput_scope must be 'Topic' or 'MessageGroup'."
  }
}

variable "encryption" {
  description = <<-EOT
    Encryption at rest. Enabled by default with the AWS-managed key
    (`alias/aws/sns`), which has no cost: a topic in the clear is AWS's default, not a
    choice.

    **Careful with service publishers.** S3, EventBridge and the other AWS services
    cannot use the AWS-managed key: publishing to a topic encrypted with
    `alias/aws/sns` from a bucket fails with a `KMSAccessDenied` that appears nowhere
    in Terraform. Those cases need a CMK with a key policy that authorizes the service
    — and the module stops the plan if you declare `allow_publish_from` without one.
  EOT
  type = object({
    managed    = optional(bool, true)
    kms_key_id = optional(string)
  })
  default = {}
}

variable "subscriptions" {
  description = <<-EOT
    The topic's subscriptions towards destinations **other than SQS**: lambda, email,
    https, sms, firehose, application.

    Subscriptions towards SQS are declared on [`modules/queue`](../queue), not here.
    SQS allows a single `Policy` attribute per queue: with several topics publishing
    onto the same queue you need one document with one statement per topic, and the
    only place that can be guaranteed from is the queue. Declaring them here would
    leave only the last policy written alive, with no errors.

        subscriptions = {
          processor = { protocol = "lambda", endpoint = module.processor.arn }
          oncall    = { protocol = "email",  endpoint = "oncall@acme.example" }
        }
  EOT
  type = map(object({
    protocol              = string
    endpoint              = string
    filter_policy         = optional(string)
    filter_policy_scope   = optional(string, "MessageAttributes")
    raw_message_delivery  = optional(bool)
    delivery_policy       = optional(string)
    redrive_policy        = optional(string)
    replay_policy         = optional(string)
    subscription_role_arn = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for s in values(var.subscriptions) : s.protocol != "sqs"])
    error_message = "Subscriptions towards SQS are declared on modules/queue, through its `subscriptions` variable: SQS allows a single policy per queue, so fan-in from several topics can only be correct if declared on the queue side."
  }

  validation {
    condition = alltrue([
      for s in values(var.subscriptions) :
      contains(["lambda", "email", "email-json", "http", "https", "sms", "firehose", "application"], s.protocol)
    ])
    error_message = "protocol must be one of lambda, email, email-json, http, https, sms, firehose, application."
  }

  validation {
    condition = alltrue([
      for s in values(var.subscriptions) : s.protocol != "firehose" || s.subscription_role_arn != null
    ])
    error_message = "A firehose subscription requires subscription_role_arn."
  }

  validation {
    condition = alltrue([
      for s in values(var.subscriptions) : contains(["MessageAttributes", "MessageBody"], s.filter_policy_scope)
    ])
    error_message = "filter_policy_scope must be 'MessageAttributes' or 'MessageBody'."
  }
}

variable "allow_publish_from" {
  description = <<-EOT
    AWS services authorized to publish to this topic — S3 notifications, EventBridge
    rules, CloudWatch alarms.

    Every entry must have `source_arn` or `source_account`: without a condition the
    policy would authorize any resource of that service in any account.

    `source_arn` must be passed as a literal string and not as a reference to the
    resource when the resource in turn depends on this topic — a notifying bucket, for
    example: that would be a cycle between the two modules.
  EOT
  type = list(object({
    service        = string
    source_arn     = optional(string)
    source_account = optional(string)
  }))
  default = []

  validation {
    condition = alltrue([
      for a in var.allow_publish_from : (a.source_arn != null) != (a.source_account != null)
    ])
    error_message = "Every allow_publish_from entry must state either `source_arn` or `source_account`, not both and not neither."
  }

  validation {
    condition = alltrue([
      for a in var.allow_publish_from :
      can(regex("^[a-z0-9.-]+$", a.service)) && !endswith(a.service, ".amazonaws.com")
    ])
    error_message = "service must be the service's short name (e.g. 's3', 'events', 'cloudwatch'), without '.amazonaws.com'."
  }
}

variable "extra_policy_statements" {
  description = "Additional statements for the topic's policy, in the format the upstream module accepts."
  type        = map(any)
  default     = {}
}

variable "delivery_policy" {
  description = "The topic's delivery policy JSON, for retry policies on HTTP destinations."
  type        = string
  default     = null
}

variable "archive_policy" {
  description = "Archive policy JSON, for message replay on FIFO topics."
  type        = string
  default     = null
}

variable "tracing_config" {
  description = "Propagation of X-Ray traces through the topic. 'Active' to propagate, 'PassThrough' to generate no segments."
  type        = string
  default     = "PassThrough"

  validation {
    condition     = contains(["Active", "PassThrough"], var.tracing_config)
    error_message = "tracing_config must be 'Active' or 'PassThrough'."
  }
}

variable "alarms" {
  description = <<-EOT
    Alarms on undelivered notifications.

    `NumberOfNotificationsFailed` is the only signal that a delivery is failing: SNS
    retries and then drops the message, without the publisher knowing anything about
    it. The threshold is **one** notification.
  EOT
  type = object({
    enabled          = optional(bool, true)
    actions          = optional(list(string), [])
    ok_actions       = optional(list(string), [])
    failed_threshold = optional(number, 1)
    failed_period    = optional(number, 300)
  })
  default = {}
}
