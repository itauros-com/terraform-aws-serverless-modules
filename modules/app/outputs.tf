output "wiring" {
  description = <<-EOT
    The graph of resolved references, by key. It is the output to read in a review: it says
    what is connected to what without having to work it out from the configuration.
  EOT
  value = {
    queue_subscriptions = { for qk, subs in local.queue_subscriptions : qk => sort(keys(subs)) }
    queue_bucket_sources = {
      for qk, srcs in local.queue_bucket_sources : qk => sort([for s in srcs : s.source_arn])
      if length(srcs) > 0
    }
    api_route_authorization = { for k, m in module.http_apis : k => m.route_authorization }
    api_invoked_functions   = { for k, m in module.http_apis : k => m.invoked_function_keys }
    schedule_targets        = local.schedule_target_types
    function_iam            = { for k, m in module.functions : k => m.iam }
  }

  # The references checked here are the ones this module introduces, that is the by-key ones
  # between one primitive and another. The ones internal to a primitive — `env_from`, `grants`,
  # an API's routes — are checked by the modules that receive them, with their own messages.
  precondition {
    condition = length(local.wiring_errors) == 0
    error_message = format(
      "Unresolved cross-references:\n  - %s",
      join("\n  - ", local.wiring_errors),
    )
  }
}

# ------------------------------------------------------------------------------
# Resources
# ------------------------------------------------------------------------------

output "functions" {
  description = "Name, ARN, log group and IAM decisions of every function, by key."
  value = {
    for k, m in module.functions : k => {
      name       = m.name
      arn        = m.arn
      invoke_arn = m.invoke_arn
      role_arn   = m.role_arn
      log_group  = m.log_group_name
      iam        = m.iam
    }
  }
}

output "http_apis" {
  description = "Endpoint, invocation URL and effective per-route authorization of every API."
  value = {
    for k, m in module.http_apis : k => {
      id                  = m.id
      endpoint            = m.endpoint
      invoke_url          = m.invoke_url
      domain_name         = m.domain_name
      route_authorization = m.route_authorization
    }
  }
}

output "queues" {
  description = "ARN, name, URL and DLQ of every queue."
  value = {
    for k, m in module.queues : k => {
      arn      = m.arn
      name     = m.name
      url      = m.url
      dlq_arn  = m.dlq_arn
      dlq_name = m.dlq_name
    }
  }
}

output "topics" {
  description = "ARN and name of every topic."
  value       = { for k, m in module.topics : k => { arn = m.arn, name = m.name } }
}

output "tables" {
  description = "ARN, name and stream ARN of every table."
  value = {
    for k, m in module.tables : k => {
      arn        = m.arn
      name       = m.name
      stream_arn = m.stream_arn
    }
  }
}

output "buckets" {
  description = "ARN and name of every bucket."
  value       = { for k, m in module.buckets : k => { arn = m.arn, name = m.name } }
}

output "secrets" {
  description = "ARN and name of every secret, plus whether the value is managed by Terraform."
  value = {
    for k, m in module.secrets : k => {
      arn                        = m.arn
      name                       = m.name
      value_managed_by_terraform = m.value_managed_by_terraform
    }
  }
}

output "security_groups" {
  description = "ID and VPC of every security group."
  value       = { for k, m in module.security_groups : k => { id = m.id, vpc_id = m.vpc_id } }
}

output "registries" {
  description = "URL and name of every ECR repository. The URLs are the base of the container functions' `image`."
  value       = { for k, m in module.registries : k => { url = m.url, name = m.name } }
}

output "schedules" {
  description = "ARN, name and target type of every schedule."
  value = {
    for k, m in module.schedules : k => {
      arn         = m.arn
      name        = m.name
      target_type = m.target_type
    }
  }
}

output "sites" {
  description = "Distribution, domain name and bucket of every site. The bucket is the target of the syncs from CI."
  value = {
    for k, m in module.sites : k => {
      distribution_id = m.distribution_id
      domain_name     = m.domain_name
      bucket_name     = m.bucket_name
    }
  }
}

# ------------------------------------------------------------------------------
# Observability
# ------------------------------------------------------------------------------

output "alarm_topic_arn" {
  description = "ARN of the alarm topic, wired automatically into every primitive. Null when observability is disabled."
  value       = local.create_alarm_topic ? module.alarm_topic[0].arn : null
}

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard. Null when observability is disabled or there is nothing to show."
  value       = var.observability.enabled ? module.observability[0].dashboard_name : null
}

output "alarm_arns" {
  description = "All the ARNs of the alarms created by the primitives, for use in an external composite alarm."
  value       = local.all_alarm_arns
}

# ------------------------------------------------------------------------------
# Registry
# ------------------------------------------------------------------------------

output "resources" {
  description = <<-EOT
    The resource registry exactly as it was passed to the functions.

    It is there to extend the application with modules not covered by this composition: a
    function declared separately receives the same registry and the references resolve with the
    same keys.
  EOT
  value       = local.resources
}
