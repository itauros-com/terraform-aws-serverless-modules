variable "grants" {
  description = <<-EOT
    Permissions declared by intent, not as a list of actions.

    The keys take the form `<type>/<name>`, where the type is one of `bucket`,
    `table`, `topic`, `queue`, `secret` and the name is the resource's key in
    `resources`. The type prefix is mandatory because the same name can belong to
    different services: a topic `operations` and a queue `operations` coexist
    perfectly well.

    The values are the capabilities granted. Valid capabilities per type:

      bucket → read, write
      table  → read, write, scan
      topic  → publish
      queue  → publish, consume
      secret → read

    Example:

        grants = {
          "bucket/documents" = ["read", "write"]
          "table/tenants"    = ["read", "scan"]
          "queue/emails"     = ["consume"]
        }
  EOT
  type        = map(list(string))
  default     = {}

  validation {
    condition = alltrue([
      for k in keys(var.grants) : can(regex("^(bucket|table|topic|queue|secret)/.+$", k))
    ])
    error_message = format(
      "Malformed grants keys: %s. Required format: '<bucket|table|topic|queue|secret>/<name>'.",
      join(", ", [for k in keys(var.grants) : format("'%s'", k) if !can(regex("^(bucket|table|topic|queue|secret)/.+$", k))])
    )
  }

  validation {
    condition     = alltrue([for caps in values(var.grants) : length(caps) > 0])
    error_message = "Every grants entry must list at least one capability."
  }

  validation {
    condition = alltrue([
      for caps in values(var.grants) : length(caps) == length(distinct(caps))
    ])
    error_message = "Duplicate capabilities within the same grants entry."
  }
}

variable "resources" {
  description = <<-EOT
    The registry of resources that grants and references can point to.

    `arn` is always required. `name` and `url` are used to resolve references
    (`env_from` in `modules/function`) and are optional here. `kms_key_arn` must be
    set when the resource is encrypted with a CMK: in that case the necessary KMS
    permissions are added automatically.

    The same registry is passed to `modules/grants` and to `modules/function`.
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

variable "extra_statements" {
  description = <<-EOT
    Literal IAM statements, for services outside the capability table (SES,
    Bedrock, third-party services, cases with unusual conditions).

    This is a deliberate escape hatch: the capability table covers the five services
    of serverless wiring, not the whole of AWS. Do not use it to work around the
    capabilities on services that are already covered.
  EOT
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

  validation {
    condition     = alltrue([for s in var.extra_statements : contains(["Allow", "Deny"], s.effect)])
    error_message = "effect must be 'Allow' or 'Deny'."
  }

  validation {
    condition     = alltrue([for s in var.extra_statements : length(s.actions) > 0 && length(s.resources) > 0])
    error_message = "Every extra_statement must have at least one action and at least one resource."
  }
}
