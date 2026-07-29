variable "name" {
  description = "The secret's name. If `prefix` is set the final name is `<prefix>-<name>`."
  type        = string
}

variable "prefix" {
  description = "Naming prefix, typically `<project>-<environment>`."
  type        = string
  default     = null
}

variable "description" {
  description = "The secret's description. It is worth writing what it contains and who populates it, because the value is not readable from the code."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}

variable "kms_key_id" {
  description = "The CMK to encrypt the secret with. Null uses the AWS-managed key for Secrets Manager."
  type        = string
  default     = null
}

variable "recovery_window_in_days" {
  description = <<-EOT
    Recovery window after deletion. The default of 30 days is AWS's.

    `0` deletes immediately and allows recreating a secret with the same name right
    afterwards: this is needed in throwaway environments, where otherwise a `destroy`
    followed by an `apply` fails because the name is still scheduled for deletion.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.recovery_window_in_days == 0 || (var.recovery_window_in_days >= 7 && var.recovery_window_in_days <= 30)
    error_message = "recovery_window_in_days must be 0 (immediate deletion) or between 7 and 30."
  }
}

variable "initial_value" {
  description = <<-EOT
    Initial value, **to be avoided**.

    Any value passed here ends up in Terraform's state in the clear, and the state is
    readable by anyone with access to the bucket. The correct model is to leave this null
    and populate the secret out of band — from the console, from the CLI or from a
    bootstrap process — letting `ignore_value_changes` stop Terraform from bringing it
    back.

    Left null, no version is created at all: the secret exists and is empty, and
    `GetSecretValue` returns `ResourceNotFoundException` until somebody populates it. That
    is deliberate — it names the problem, where a placeholder value would be handed to the
    application and fail further downstream.

    If you use it anyway, for example for a placeholder JSON structure in a development
    environment, know that it is a conscious choice and not a default.
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "ignore_value_changes" {
  description = <<-EOT
    Ignore changes to the secret's value. **Enabled by default**: the real value is
    written by somebody else, and without this option every plan would try to bring it
    back to the content Terraform knows about, wiping out the credential in use.
  EOT
  type        = bool
  default     = true
}

variable "rotation" {
  description = <<-EOT
    Automatic rotation through a Lambda.

    The rotation function must implement the four steps AWS expects (`createSecret`,
    `setSecret`, `testSecret`, `finishSecret`): configuring rotation without a conforming
    function leaves the secret in a state where rotation fails silently on every cycle.
  EOT
  type = object({
    enabled                  = optional(bool, false)
    lambda_arn               = optional(string)
    automatically_after_days = optional(number)
    schedule_expression      = optional(string)
    duration                 = optional(string)
    rotate_immediately       = optional(bool, false)
  })
  default = {}

  validation {
    condition     = !var.rotation.enabled || var.rotation.lambda_arn != null
    error_message = "With rotation.enabled = true rotation.lambda_arn is required."
  }

  validation {
    condition = !var.rotation.enabled || (
      (var.rotation.automatically_after_days != null) != (var.rotation.schedule_expression != null)
    )
    error_message = "State exactly one of rotation.automatically_after_days and rotation.schedule_expression."
  }
}

variable "policy_statements" {
  description = "Statements for the secret's resource policy, for example for a cross-account read. In the format the upstream module accepts."
  type        = map(any)
  default     = {}
}
