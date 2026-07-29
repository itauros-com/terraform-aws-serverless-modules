output "distribution_id" {
  description = "The distribution's ID. Needed for invalidations from CI."
  value       = aws_cloudfront_distribution.this.id

  precondition {
    condition     = !local.has_aliases || var.certificate_arn != null
    error_message = "With `aliases` a `certificate_arn` is required: without it, CloudFront only serves its own domain and requests on the aliases fail in TLS."
  }

  precondition {
    condition     = length(var.aliases) > 0 || var.zone_id == null
    error_message = "`zone_id` is set but there are no `aliases`: there is no record to create."
  }
}

output "distribution_arn" {
  description = "The distribution's ARN."
  value       = aws_cloudfront_distribution.this.arn
}

output "domain_name" {
  description = "The domain name assigned by CloudFront, the one to use if there are no aliases."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "hosted_zone_id" {
  description = "CloudFront's hosted zone ID, to create alias records in a zone managed elsewhere."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}

output "bucket_name" {
  description = "Name of the content bucket. It is the target of the `aws s3 sync` calls from CI."
  value       = module.bucket.name
}

output "bucket_arn" {
  description = "ARN of the content bucket."
  value       = module.bucket.arn
}

output "bucket_registry_entry" {
  description = <<-EOT
    The bucket's registry entry, to give a function permission to write to it — for example
    to publish generated content.

        resources = { buckets = { site = module.site.bucket_registry_entry } }
  EOT
  value       = module.bucket.registry_entry
}

output "origin_access_control_id" {
  description = <<-EOT
    ID of the Origin Access Control actually associated with the origin.

    It is exposed because its absence is the defect this module corrects: an OAC that is
    created but not linked leaves the distribution working only if the bucket is public, and
    reports it in no way at all.
  EOT
  value       = aws_cloudfront_origin_access_control.this.id
}

output "spa_error_response_codes" {
  description = "The error codes rewritten by the SPA preset. An empty list when the preset is disabled."

  # `tolist` for a stable type: a `for` expression produces a tuple, whose type changes with
  # the number of elements.
  value = tolist([for e in local.spa_error_responses : e.error_code])
}
