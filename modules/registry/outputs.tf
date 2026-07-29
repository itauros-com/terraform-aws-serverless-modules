output "url" {
  description = "The repository's URL. It is the base of the `image_uri`s: `<url>:<tag>`."
  value       = module.ecr.repository_url
}

output "arn" {
  description = "The repository's ARN."
  value       = module.ecr.repository_arn
}

output "name" {
  description = "The repository's name, already carrying the prefix namespace."
  value       = module.ecr.repository_name
}

output "registry_id" {
  description = "The registry's ID, that is the account that owns it."
  value       = module.ecr.repository_registry_id
}

output "lifecycle_rules" {
  description = <<-EOT
    The generated lifecycle rules, for inspection.

    There are two of them and they are distinct — removing the untagged ones and keeping
    the tagged ones — because merging the two into a single rule is how a policy ends up
    describing a behaviour different from the one it has.
  EOT
  value       = local.lifecycle_policy.rules
}

output "tag_mutability" {
  description = "The tag mutability mode actually applied. Derived from the inputs, hence known at plan time."
  value       = local.tag_mutability
}
