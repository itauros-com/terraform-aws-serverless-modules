variable "name" {
  description = "The bucket's name. If `prefix` is set the final name is `<prefix>-<name>`. It must be globally unique on AWS."
  type        = string
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

variable "versioning_enabled" {
  description = <<-EOT
    Object versioning. **Enabled by default**: it is the only protection against a
    wrong application-level overwrite or deletion, and there is no way to recover an
    object without it.

    It costs in storage, which you keep in check with a `lifecycle_rules` entry that
    expires the non-current versions.
  EOT
  type        = bool
  default     = true
}

variable "encryption" {
  description = <<-EOT
    Encryption at rest. `AES256` (SSE-S3) by default, at no additional cost.

    With `kms_key_arn` it switches to SSE-KMS and the **bucket key** is enabled, which
    greatly reduces KMS calls and therefore cost: without it, every GET and every PUT is
    a billable KMS request.
  EOT
  type = object({
    kms_key_arn = optional(string)
  })
  default = {}
}

variable "force_destroy" {
  description = "Lets Terraform delete a non-empty bucket. Keep it false on anything holding real data."
  type        = bool
  default     = false
}

variable "cors_rules" {
  description = "The bucket's CORS rules."
  type = list(object({
    id              = optional(string)
    allowed_methods = list(string)
    allowed_origins = list(string)
    allowed_headers = optional(list(string))
    expose_headers  = optional(list(string))
    max_age_seconds = optional(number)
  }))
  default = []

  validation {
    condition = alltrue(flatten([
      for r in var.cors_rules : [
        for m in r.allowed_methods : contains(["GET", "PUT", "POST", "DELETE", "HEAD"], m)
      ]
    ]))
    error_message = "allowed_methods only accepts GET, PUT, POST, DELETE, HEAD."
  }

  validation {
    condition     = alltrue([for r in var.cors_rules : !contains(r.allowed_origins, "*") || length(r.allowed_origins) == 1])
    error_message = "A '*' in allowed_origins makes the other listed origins pointless: use either only '*' or only explicit origins."
  }
}

variable "lifecycle_rules" {
  description = <<-EOT
    Lifecycle rules.

    `abort_incomplete_multipart_upload_days` deserves a rule on every bucket that
    receives large uploads: the fragments of aborted uploads are not visible among the
    objects but are billed indefinitely.
  EOT
  type = list(object({
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
  }))
  default = []
}

variable "notifications" {
  description = <<-EOT
    Notifications of the bucket's events towards queues, topics and functions.

    They must **all be declared here**: S3 allows a single notification configuration
    per bucket, and every write replaces the previous one entirely. Two Terraform
    resources configuring notifications on the same bucket overwrite each other,
    silently and in non-deterministic order.

    For functions the module also creates the necessary `aws_lambda_permission`: the
    permission and the notification are the same declaration, so they cannot diverge.

    The queues and topics must in turn authorize S3 to write. On the queue side you do
    that with `allow_send_from`, on the topic side with `allow_publish_from`, passing the
    bucket's ARN as a literal string so as not to create a cycle between the modules.

        notifications = {
          queues = {
            ingest = { queue_arn = module.ingest.arn, events = ["s3:ObjectCreated:*"], filter_prefix = "incoming/" }
          }
        }
  EOT
  type = object({
    queues = optional(map(object({
      queue_arn     = string
      events        = list(string)
      filter_prefix = optional(string)
      filter_suffix = optional(string)
    })), {})
    topics = optional(map(object({
      topic_arn     = string
      events        = list(string)
      filter_prefix = optional(string)
      filter_suffix = optional(string)
    })), {})
    functions = optional(map(object({
      function_arn  = string
      events        = list(string)
      filter_prefix = optional(string)
      filter_suffix = optional(string)
    })), {})
  })
  default = {}

  validation {
    condition = alltrue(flatten([
      for group in [var.notifications.queues, var.notifications.topics, var.notifications.functions] : [
        for n in values(group) : length(n.events) > 0
      ]
    ]))
    error_message = "Every notification must list at least one event (for example 's3:ObjectCreated:*')."
  }

  validation {
    condition = alltrue(flatten([
      for group in [var.notifications.queues, var.notifications.topics, var.notifications.functions] : [
        for n in values(group) : [for e in n.events : startswith(e, "s3:")]
      ]
    ]))
    error_message = "The events must be S3 event names, starting with 's3:'."
  }
}

variable "logging" {
  description = "Server access logging towards another bucket."
  type = object({
    target_bucket = string
    target_prefix = optional(string)
  })
  default = null
}

variable "object_ownership" {
  description = <<-EOT
    Object ownership management. `BucketOwnerEnforced` disables ACLs entirely, which is
    the default AWS has recommended since 2023 and makes it impossible to expose an
    object by mistake through an ACL.
  EOT
  type        = string
  default     = "BucketOwnerEnforced"

  validation {
    condition     = contains(["BucketOwnerEnforced", "BucketOwnerPreferred", "ObjectWriter"], var.object_ownership)
    error_message = "object_ownership must be 'BucketOwnerEnforced', 'BucketOwnerPreferred' or 'ObjectWriter'."
  }
}

variable "policy_json" {
  description = <<-EOT
    The bucket's policy, as JSON.

    The module does **not** create public buckets: the public access block is always
    on. To serve static web content you use [`modules/site`](../site), which puts
    CloudFront in front of a private bucket with Origin Access Control.

    A public bucket behind CloudFront makes CloudFront bypassable: anyone who knows the
    bucket's name can read the objects from the S3 endpoint, skipping WAF, logging and
    the cache.
  EOT
  type        = string
  default     = null
}
