output "id" {
  description = "The security group's ID. It is what you pass to modules/function's `vpc.security_group_ids`."
  value       = module.sg.security_group_id

  precondition {
    condition = local.vpc_selector_count == 1
    error_message = format(
      "State exactly one of `vpc_id` and `vpc_name`: %d were given.",
      local.vpc_selector_count,
    )
  }

  # A security group with no egress rule at all blocks every outbound flow. It is a
  # legitimate configuration but almost never the intended one: a Lambda in a VPC without
  # egress does not even reach the AWS APIs and its errors are timeouts, not denied
  # permissions.
  precondition {
    condition     = !local.no_egress_at_all
    error_message = "The security group has no egress rule at all and `allow_all_egress` is false: it would block every outbound flow. If that is intended, declare an explicit egress rule; if it is not, leave `allow_all_egress = true`."
  }
}

output "arn" {
  description = "The security group's ARN."
  value       = module.sg.security_group_arn
}

output "name" {
  description = "The security group's name, already prefixed."
  value       = module.sg.security_group_name
}

output "vpc_id" {
  description = "The security group's VPC ID, resolved from the Name tag when `vpc_name` was given."
  value       = local.vpc_id
}

output "vpc_cidr" {
  description = "The VPC's CIDR, the one used to resolve the special `vpc` value in the rules."
  value       = local.vpc_cidr
}
