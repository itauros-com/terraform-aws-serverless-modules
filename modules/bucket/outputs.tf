output "arn" {
  description = "The bucket's ARN."
  value       = module.s3.s3_bucket_arn
}

output "name" {
  description = "The bucket's name, already prefixed."
  value       = module.s3.s3_bucket_id
}

output "id" {
  description = "The bucket's ID (identical to the name)."
  value       = module.s3.s3_bucket_id
}

output "domain_name" {
  description = "The bucket's domain name."
  value       = module.s3.s3_bucket_bucket_domain_name
}

output "regional_domain_name" {
  description = "The regional domain name, the one to use as a CloudFront origin."
  value       = module.s3.s3_bucket_bucket_regional_domain_name
}

output "static_arn" {
  description = <<-EOT
    The ARN computed from the name, without depending on the resource.

    It is there to break cycles: a queue receiving notifications from this bucket has to
    authorize `s3.amazonaws.com` with the bucket's ARN as a condition, but the bucket
    needs the queue's ARN for the notification. Using this output — or the equivalent
    string — the queue does not depend on the bucket.
  EOT
  value       = format("arn:aws:s3:::%s", local.bucket_name)
}

output "registry_entry" {
  description = <<-EOT
    The entry to put into the consumers' `resources` registry, already in the expected
    shape, CMK included.

        resources = { buckets = { documents = module.documents.registry_entry } }
  EOT
  value = {
    arn         = module.s3.s3_bucket_arn
    name        = module.s3.s3_bucket_id
    kms_key_arn = var.encryption.kms_key_arn
  }
}

output "notification_ids" {
  description = "The ids of the configured notifications, by destination. Used to verify they converged into a single configuration."
  value = {
    queues    = sort(keys(var.notifications.queues))
    topics    = sort(keys(var.notifications.topics))
    functions = sort(keys(var.notifications.functions))
  }
}

output "policy_json_attached" {
  description = <<-EOT
    Whether the `policy_json` passed in takes part in the bucket's policy.

    The bucket always has one — the TLS statements are unconditional — so this reports the
    caller's document alone, which is the part that a duplicate `aws_s3_bucket_policy`
    elsewhere would silently replace.
  EOT
  value       = local.attach_policy
}
