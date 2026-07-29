variable "name" {
  description = "Name of the observed application. If `prefix` is set the final name is `<prefix>-<name>`."
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

variable "alarm_topic" {
  description = <<-EOT
    The SNS topic to deliver the alarms to. Its ARN then has to be passed to every other
    module's `alarms.actions` — which is why this module is declared **before** the others.

    **Encryption is disabled by default**, unlike in `modules/topic`. CloudWatch cannot use
    the AWS-managed key: with `alias/aws/sns` the alarms would not arrive, and the failure
    is silent because an alarm that fails to notify does not itself raise an alarm. To
    encrypt it you need a CMK whose key policy authorizes `cloudwatch.amazonaws.com`.
  EOT
  type = object({
    create     = optional(bool, true)
    kms_key_id = optional(string)
    subscriptions = optional(map(object({
      protocol = string
      endpoint = string
    })), {})
  })
  default = {}
}

variable "existing_alarm_topic_arn" {
  description = "ARN of an already existing topic to use instead of creating one. Requires `alarm_topic.create = false`."
  type        = string
  default     = null
}

variable "dashboard_enabled" {
  description = "Creates a CloudWatch dashboard with the declared resources. Dashboards are free up to three per account, then they carry a monthly cost."
  type        = bool
  default     = true
}

variable "functions" {
  description = "Names of the Lambda functions to include in the dashboard."
  type        = list(string)
  default     = []
}

variable "queues" {
  description = "Names of the SQS queues to include in the dashboard. Include the DLQs too: that is where you see whether something is failing."
  type        = list(string)
  default     = []
}

variable "tables" {
  description = "Names of the DynamoDB tables to include in the dashboard."
  type        = list(string)
  default     = []
}

variable "apis" {
  description = "HTTP API Gateways to include in the dashboard, with their id and stage."
  type = list(object({
    id    = string
    stage = optional(string, "$default")
  }))
  default = []
}

variable "region" {
  description = "Region used in the dashboard's metrics. Null infers it from the provider."
  type        = string
  default     = null
}

variable "log_shipping" {
  description = <<-EOT
    Forwarding of the logs to an external destination — typically a Firehose or a Lambda
    that writes to Loki.

    `role_arn` is required for Firehose and Kinesis destinations, not for a Lambda: in the
    latter case what is needed instead is an `aws_lambda_permission` on the destination
    function, which this module does not create because the function may live in another
    account.

    An empty `filter_pattern` forwards everything. It is worth narrowing it down:
    forwarding is billed by volume and the debug logs of a verbose Lambda cost more than
    they are worth.
  EOT
  type = object({
    destination_arn = string
    role_arn        = optional(string)
    filter_pattern  = optional(string, "")
    log_groups      = optional(list(string), [])
  })
  default = null

  validation {
    condition     = var.log_shipping == null || length(var.log_shipping.log_groups) > 0
    error_message = "log_shipping requires at least one log group in `log_groups`: a destination with no sources forwards nothing."
  }
}

variable "composite_alarm" {
  description = <<-EOT
    A composite alarm that fires when at least one of the listed alarms is in alarm.

    It is there to cut the noise: with twenty alarms on an application, one incident lights
    up six of them and whoever is on call receives six notifications for a single problem.
    The composite alarm notifies once, and the individual ones stay for the diagnosis.
  EOT
  type = object({
    enabled    = optional(bool, false)
    alarm_arns = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = !var.composite_alarm.enabled || length(var.composite_alarm.alarm_arns) > 1
    error_message = "A composite alarm makes sense with at least two alarms: with only one it adds a layer of indirection without reducing anything."
  }
}
