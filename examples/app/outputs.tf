output "api_endpoint" {
  description = "The API's invocation URL."
  value       = module.app.http_apis["apigw"].invoke_url
}

output "site_domain" {
  description = "The static site's CloudFront domain name."
  value       = module.app.sites["web"].domain_name
}

output "site_bucket" {
  description = "The site's content bucket. It is the target of the syncs from CI."
  value       = module.app.sites["web"].bucket_name
}

output "image_repository" {
  description = "The ECR repository's URL. It is the base of the container functions' `image`."
  value       = module.app.registries["files"].url
}

output "function_names" {
  description = "The functions' names, for out-of-band deploys from CI."
  value       = { for k, f in module.app.functions : k => f.name }
}

output "wiring" {
  description = <<-EOT
    The graph of resolved references. It is the output to read in a review: it says which routes
    are public, which functions have the network permissions, and which topics every queue
    receives from.
  EOT
  value       = module.app.wiring
}

output "alarm_topic_arn" {
  description = "The alarm topic, wired automatically into every primitive."
  value       = module.app.alarm_topic_arn
}

output "dashboard_name" {
  description = "The application's CloudWatch dashboard."
  value       = module.app.dashboard_name
}
