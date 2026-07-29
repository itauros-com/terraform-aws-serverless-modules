output "api" {
  description = "Name, invocation ARN and log group of the HTTP function."
  value = {
    name       = module.api.name
    invoke_arn = module.api.invoke_arn
    log_group  = module.api.log_group_name
  }
}

output "worker" {
  description = "Name of the consumer function and its event source mappings."
  value = {
    name              = module.worker.name
    event_source_arns = module.worker.event_source_mapping_arns
  }
}

output "iam_decisions" {
  description = <<-EOT
    What the module decided to attach for each function. `network` must be false on all three:
    none of them is in a VPC, so none of them must have the ENI permissions.
  EOT
  value = {
    api     = module.api.iam
    worker  = module.worker.iam
    minimal = module.minimal.iam
  }
}

output "api_policy" {
  description = "The policy generated from the HTTP function's grants, for inspection."
  value       = module.api.policy_json
}
