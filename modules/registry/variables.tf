variable "name" {
  description = "The repository's name. If `prefix` is set the final name is `<prefix>/<name>` — a slash instead of a dash because ECR uses paths as namespaces."
  type        = string
}

variable "prefix" {
  description = "Naming prefix, used as the repository's namespace."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}

variable "immutable_tags" {
  description = <<-EOT
    Immutable tags. **Enabled by default**: without them, a `docker push` on the same tag
    changes the deployed code without any configuration changing, and rollback by revert
    no longer works because the tag no longer identifies an image.

    `mutable_tag_patterns` lists the exceptions, typically the moving tags of development
    environments.
  EOT
  type        = bool
  default     = true
}

variable "mutable_tag_patterns" {
  description = "Tag patterns excluded from immutability, wildcard style. At most 5, as AWS requires."
  type        = list(string)
  default     = ["latest", "dev-*"]

  validation {
    condition     = length(var.mutable_tag_patterns) <= 5
    error_message = "AWS allows at most 5 immutability exclusion patterns."
  }
}

variable "scan_on_push" {
  description = "Vulnerability scanning on push. Enabled by default: it is free in basic mode and the only alternative is not knowing."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "CMK to encrypt the images. Null uses the AES256 encryption managed by ECR."
  type        = string
  default     = null
}

variable "force_delete" {
  description = "Allows deleting the repository even if it contains images. Keep it false on anything production needs."
  type        = bool
  default     = false
}

variable "untagged_expire_days" {
  description = <<-EOT
    Days after which an untagged image is removed.

    Untagged images are the ones replaced by a later push on the same tag: they are
    referenced by nothing and are billed as long as they stay.
  EOT
  type        = number
  default     = 1
}

variable "keep_tagged_images" {
  description = <<-EOT
    How many tagged images to keep for each prefix in `retained_tag_prefixes`. The oldest
    ones beyond this number are removed.

    It must be kept high enough to cover the rollback window: if you keep 10 images and
    release 20 a day, rolling back to yesterday is not possible.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.keep_tagged_images >= 1 && var.keep_tagged_images <= 1000
    error_message = "keep_tagged_images must be between 1 and 1000."
  }
}

variable "retained_tag_prefixes" {
  description = "Prefixes of the tags subject to the retention rule. Images with other tags are never removed automatically."
  type        = list(string)
  default     = ["v"]

  validation {
    condition     = length(var.retained_tag_prefixes) > 0
    error_message = "At least one prefix is required: a retention rule with no prefixes selects nothing and removes nothing."
  }
}

variable "read_access_arns" {
  description = "Principals authorized to read from the repository, for example the roles of another account."
  type        = list(string)
  default     = []
}

variable "lambda_read_access_arns" {
  description = <<-EOT
    Lambda functions authorized to read the images.

    It is needed because a container-based Lambda needs a permission **on the repository's
    policy**, not only on its own role: without it, the function's creation fails with an
    error that talks about an image not found.
  EOT
  type        = list(string)
  default     = []
}
