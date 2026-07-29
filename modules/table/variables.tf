variable "name" {
  description = "The table's name. If `prefix` is set the final name is `<prefix>-<name>`."
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

variable "attributes" {
  description = <<-EOT
    Attributes that take part in a key or in an index, in the form `name = type` with
    type `S` (string), `N` (number) or `B` (binary).

    **Only** the attributes used as a key must be declared: DynamoDB is schemaless for
    everything else, and declaring an attribute used by no key makes the table's
    creation fail.

        attributes = { pk = "S", sk = "S", gsi1pk = "S" }
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([for t in values(var.attributes) : contains(["S", "N", "B"], t)])
    error_message = format(
      "Attribute types must be 'S', 'N' or 'B'. Non-conforming: %s.",
      join(", ", [for k, t in var.attributes : format("%s = '%s'", k, t) if !contains(["S", "N", "B"], t)]),
    )
  }
}

variable "hash_key" {
  description = "The partition key's attribute. It must be declared in `attributes`."
  type        = string
}

variable "range_key" {
  description = "The sort key's attribute. It must be declared in `attributes`. Null for a table with a partition key only."
  type        = string
  default     = null
}

variable "billing_mode" {
  description = <<-EOT
    `PAY_PER_REQUEST` or `PROVISIONED`.

    The default is on-demand: it does not require estimating traffic, it does not
    throttle on a spike and for the irregular workloads typical of serverless it costs
    less. `PROVISIONED` is worth it on high and predictable traffic, and in that case
    consider `autoscaling` too.
  EOT
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.billing_mode)
    error_message = "billing_mode must be 'PAY_PER_REQUEST' or 'PROVISIONED'."
  }
}

variable "read_capacity" {
  description = "Provisioned read capacity. Ignored in on-demand mode."
  type        = number
  default     = null
}

variable "write_capacity" {
  description = "Provisioned write capacity. Ignored in on-demand mode."
  type        = number
  default     = null
}

variable "global_secondary_indexes" {
  description = <<-EOT
    Global secondary indexes, with the map's key as the index's name.

    `projection_type = "ALL"` is the default because it is the one that does not
    surprise: an index with a `KEYS_ONLY` projection forces the application into a
    second read against the table for every result, and you only notice the problem by
    measuring RCUs.

        global_secondary_indexes = {
          gsi1 = { hash_key = "gsi1pk", range_key = "sk" }
        }
  EOT
  type = map(object({
    hash_key           = string
    range_key          = optional(string)
    projection_type    = optional(string, "ALL")
    non_key_attributes = optional(list(string))
    read_capacity      = optional(number)
    write_capacity     = optional(number)
  }))
  default = {}

  validation {
    condition = alltrue([
      for i in values(var.global_secondary_indexes) :
      contains(["ALL", "KEYS_ONLY", "INCLUDE"], i.projection_type)
    ])
    error_message = "projection_type must be 'ALL', 'KEYS_ONLY' or 'INCLUDE'."
  }

  validation {
    condition = alltrue([
      for i in values(var.global_secondary_indexes) :
      i.projection_type != "INCLUDE" || (i.non_key_attributes != null && length(coalesce(i.non_key_attributes, [])) > 0)
    ])
    error_message = "An index with projection_type = 'INCLUDE' requires non_key_attributes."
  }

  validation {
    condition = alltrue([
      for i in values(var.global_secondary_indexes) :
      i.projection_type == "INCLUDE" || i.non_key_attributes == null
    ])
    error_message = "non_key_attributes only makes sense with projection_type = 'INCLUDE'."
  }
}

variable "local_secondary_indexes" {
  description = <<-EOT
    Local secondary indexes, with the map's key as the index's name. They share the
    table's partition key and **can only be created when the table is created**: adding
    one later requires recreating it.
  EOT
  type = map(object({
    range_key          = string
    projection_type    = optional(string, "ALL")
    non_key_attributes = optional(list(string))
  }))
  default = {}

  validation {
    condition = alltrue([
      for i in values(var.local_secondary_indexes) :
      contains(["ALL", "KEYS_ONLY", "INCLUDE"], i.projection_type)
    ])
    error_message = "projection_type must be 'ALL', 'KEYS_ONLY' or 'INCLUDE'."
  }
}

variable "ttl" {
  description = <<-EOT
    Time to live. The named attribute must contain a Unix timestamp in seconds;
    DynamoDB deletes expired items without consuming write capacity.
  EOT
  type = object({
    enabled        = optional(bool, false)
    attribute_name = optional(string, "expires_at")
  })
  default = {}

  validation {
    condition     = !var.ttl.enabled || var.ttl.attribute_name != null
    error_message = "With ttl.enabled = true an attribute_name is required."
  }
}

variable "point_in_time_recovery" {
  description = <<-EOT
    Point-in-time recovery. **Enabled by default**: it is the only defence against a
    wrong application-level deletion, and without it there is no way back.

    It costs in proportion to the table's size, so on pure caching or rebuildable tables
    it is disabled explicitly.
  EOT
  type = object({
    enabled        = optional(bool, true)
    period_in_days = optional(number)
  })
  default = {}
}

variable "deletion_protection" {
  description = <<-EOT
    Deletion protection. **Enabled by default**: a table holds state and must be
    protected from an absent-minded `terraform destroy` or from a refactoring that
    changes its address.

    It must be set to `false` on throwaway tables — this repo's examples do that,
    otherwise their `destroy` would not work.
  EOT
  type        = bool
  default     = true
}

variable "stream" {
  description = <<-EOT
    DynamoDB Stream, to react to changes with a Lambda or to replicate elsewhere.

    `NEW_AND_OLD_IMAGES` is the default when the stream is enabled because it is the
    only type that allows computing a delta; changing it later requires recreating the
    stream and the consumers lose their position.
  EOT
  type = object({
    enabled   = optional(bool, false)
    view_type = optional(string, "NEW_AND_OLD_IMAGES")
  })
  default = {}

  validation {
    condition = !var.stream.enabled || contains(
      ["KEYS_ONLY", "NEW_IMAGE", "OLD_IMAGE", "NEW_AND_OLD_IMAGES"], var.stream.view_type
    )
    error_message = "stream.view_type must be 'KEYS_ONLY', 'NEW_IMAGE', 'OLD_IMAGE' or 'NEW_AND_OLD_IMAGES'."
  }
}

variable "encryption" {
  description = <<-EOT
    Encryption at rest. DynamoDB always encrypts; `kms_key_arn` replaces the AWS-owned
    key with a CMK, which is what you need when you want to control rotation or revoke
    access to the data.

    With a CMK, the consumers need KMS permissions: pass `registry_entry` to their
    registry and the grants generate them on their own.
  EOT
  type = object({
    kms_key_arn = optional(string)
  })
  default = {}
}

variable "table_class" {
  description = "'STANDARD' or 'STANDARD_INFREQUENT_ACCESS'. The latter reduces storage cost and increases access cost."
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "STANDARD_INFREQUENT_ACCESS"], var.table_class)
    error_message = "table_class must be 'STANDARD' or 'STANDARD_INFREQUENT_ACCESS'."
  }
}

variable "autoscaling" {
  description = "Autoscaling of the provisioned capacities. Ignored in on-demand mode."
  type = object({
    enabled  = optional(bool, false)
    defaults = optional(map(string), {})
    read     = optional(map(string), {})
    write    = optional(map(string), {})
    indexes  = optional(map(map(string)), {})
  })
  default = {}
}

variable "alarms" {
  description = <<-EOT
    Alarms on throttling and system errors.

    In on-demand mode throttling does not depend on the configured capacity but on
    partition limits: it happens when the keys are badly distributed, and it is the
    signal that the data model needs revisiting. It is worth seeing.
  EOT
  type = object({
    enabled            = optional(bool, true)
    actions            = optional(list(string), [])
    ok_actions         = optional(list(string), [])
    throttle_threshold = optional(number, 1)
    throttle_period    = optional(number, 300)
    error_threshold    = optional(number, 1)
    error_period       = optional(number, 300)
  })
  default = {}
}
