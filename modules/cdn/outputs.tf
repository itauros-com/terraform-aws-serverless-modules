output "distribution_id" {
  description = "The distribution's ID, the one to pass to a cache invalidation."
  value       = aws_cloudfront_distribution.this.id

  # The cross-references this module introduces, reported together and with the place they
  # are declared. Raised where they occur they would surface as an "Invalid index" naming
  # neither the behavior nor what is wrong with it.
  precondition {
    condition = length(local.reference_errors) == 0
    error_message = format(
      "Unresolved references:\n  - %s",
      join("\n  - ", local.reference_errors),
    )
  }

  # Aliases without a certificate mean CloudFront serves them with its own certificate,
  # which is valid for `*.cloudfront.net` and for nothing else: every viewer gets a TLS
  # error. AWS accepts the configuration.
  precondition {
    condition     = length(var.aliases) == 0 || var.certificate_arn != null
    error_message = "`aliases` are declared without `certificate_arn`: CloudFront would serve them with its default certificate, which is valid only for *.cloudfront.net, and every viewer would get a TLS error."
  }

  # A record pointing at a distribution that does not answer for that name is a broken
  # domain, not a missing one.
  precondition {
    condition     = var.zone_id == null || length(var.aliases) > 0
    error_message = "`zone_id` is set but there are no `aliases`: there is no name to create a record for."
  }
}

output "distribution_arn" {
  description = "The distribution's ARN. It is what scopes the buckets' OAC statement."
  value       = aws_cloudfront_distribution.this.arn
}

output "domain_name" {
  description = "The `cloudfront.net` domain name, the target of the DNS records."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "hosted_zone_id" {
  description = "The zone ID to use in a Route53 alias record towards the distribution."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}

output "origin_access_control_ids" {
  description = "The OAC of every bucket origin, by origin key."
  value       = { for k, o in aws_cloudfront_origin_access_control.this : k => o.id }
}

output "key_group_ids" {
  description = <<-EOT
    The key groups' IDs, by key. They are not the value used to sign: a signed URL carries
    the **public key's** ID in `Key-Pair-Id`, which is in `public_key_ids`.
  EOT
  value       = { for k, g in aws_cloudfront_key_group.this : k => g.id }
}

output "public_key_ids" {
  description = <<-EOT
    The public keys' IDs, keyed `<key group>/<key>`. It is the value that goes in the signed
    URL's `Key-Pair-Id`, so whoever signs reads it from here instead of copying it from the
    console.
  EOT
  value       = { for k, p in aws_cloudfront_public_key.this : k => p.id }
}

output "bucket_policy_json" {
  description = <<-EOT
    The read statement for each bucket origin, by origin key, ready for
    `modules/bucket.policy_json` with `attach_policy = true`.

    It has to go through the bucket module: S3 keeps **one policy document per bucket** and
    every write replaces it whole, so a separate `aws_s3_bucket_policy` here would silently
    drop the statements the bucket module always attaches — the deny on insecure transport
    among them — with neither Terraform nor AWS reporting the conflict.
  EOT
  value       = local.bucket_policy_json
}

output "bucket_policy_statements" {
  description = <<-EOT
    The same statements as `bucket_policy_json`, as objects rather than a document.

    It is what a composition needs: a bucket fronted by two distributions has two statements
    in the one policy S3 allows it, and merging them structurally is the only way — a
    document embeds the distribution's ARN, which is unknown at plan, so `jsondecode` on it
    yields an unknown value nobody can index into.
  EOT
  value       = local.bucket_policy_statements
}

output "behaviors" {
  description = <<-EOT
    The resolved behaviors, in evaluation order, with what each preset expanded to. It is
    the output to read in a review: it says which path reaches which origin, whether it is
    cached and whether it is signed, without working it back out of the configuration.
  EOT
  value = [
    for b in concat([local.default_behavior_resolved], local.ordered_behaviors) : {
      path_pattern = coalesce(b.path_pattern, "(default)")
      origin       = b.origin
      methods      = b.allowed_methods
      signed       = length(b.trusted_key_groups) > 0
    }
  ]
}
