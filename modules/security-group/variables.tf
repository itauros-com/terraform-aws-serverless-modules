variable "name" {
  description = "The security group's name. If `prefix` is set the final name is `<prefix>-<name>`."
  type        = string
}

variable "prefix" {
  description = "Naming prefix, typically `<project>-<environment>`."
  type        = string
  default     = null
}

variable "description" {
  description = "The security group's description. AWS does not allow changing it after creation."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "The VPC's ID. An alternative to `vpc_name`: state exactly one of them."
  type        = string
  default     = null

  validation {
    condition     = var.vpc_id == null || startswith(coalesce(var.vpc_id, ""), "vpc-")
    error_message = "vpc_id must start with 'vpc-'. To identify the VPC from its Name tag use `vpc_name`."
  }
}

variable "vpc_name" {
  description = <<-EOT
    Value of the VPC's `Name` tag, resolved to an ID with a lookup. An alternative to
    `vpc_id`: state exactly one of them.

    It is what you need when the VPC is created elsewhere and its ID changes between
    environments: the name stays stable and the environments' configuration stays
    identical.
  EOT
  type        = string
  default     = null
}

variable "ingress_cidr_rules" {
  description = <<-EOT
    Ingress rules from CIDR blocks.

    `cidr_blocks` also accepts the special value `vpc`, which is resolved to the CIDR of
    the security group's VPC: it saves replicating the CIDR in every environment and
    getting it wrong in one.
  EOT
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = optional(string, "tcp")
    cidr_blocks = string
    description = optional(string)
  }))
  default = []
}

variable "ingress_source_sg_rules" {
  description = "Ingress rules from another security group."
  type = list(object({
    from_port                = number
    to_port                  = number
    protocol                 = optional(string, "tcp")
    source_security_group_id = string
    description              = optional(string)
  }))
  default = []
}

variable "ingress_self_rules" {
  description = "Ingress rules from the security group itself, for traffic between resources that share it."
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = optional(string, "tcp")
    description = optional(string)
  }))
  default = []
}

variable "egress_cidr_rules" {
  description = "Egress rules towards CIDR blocks. `cidr_blocks` accepts the special value `vpc`, as on ingress."
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = optional(string, "tcp")
    cidr_blocks = string
    description = optional(string)
  }))
  default = []
}

variable "egress_source_sg_rules" {
  description = "Egress rules towards another security group."
  type = list(object({
    from_port                = number
    to_port                  = number
    protocol                 = optional(string, "tcp")
    source_security_group_id = string
    description              = optional(string)
  }))
  default = []
}

variable "egress_self_rules" {
  description = "Egress rules towards the security group itself."
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = optional(string, "tcp")
    description = optional(string)
  }))
  default = []
}

variable "allow_all_egress" {
  description = <<-EOT
    Allows all outbound traffic. **Enabled by default**, because it is what a Lambda in a
    VPC needs to reach the AWS APIs and without which nothing works — and because it is
    the behaviour of AWS's default security group.

    The better configuration is to disable it and open only what is needed, together with
    VPC endpoints for the AWS services: you also save the NAT gateway. But it is a choice
    to be made, not a default that breaks things.

    Setting it to `false` without declaring any egress rule makes the security group block
    every outbound flow: the module reports that.
  EOT
  type        = bool
  default     = true
}

variable "revoke_rules_on_delete" {
  description = "Revoke all the rules before deleting the security group. Avoids being blocked by cyclic dependencies between groups."
  type        = bool
  default     = true
}
