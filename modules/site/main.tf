locals {
  site_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.site_name })

  origin_id = "s3-${local.site_name}"

  # With the SPA preset a deep URL handled by the client-side router does not exist as an
  # object: the origin answers 403 (private bucket with OAC) or 404, and it has to be
  # rewritten to the index.
  spa_error_responses = var.spa ? [
    { error_code = 403, response_code = 200, response_page_path = "/${var.default_root_object}", error_caching_min_ttl = 10 },
    { error_code = 404, response_code = 200, response_page_path = "/${var.default_root_object}", error_caching_min_ttl = 10 },
  ] : []

  error_responses = concat(local.spa_error_responses, [
    for e in var.custom_error_responses : {
      error_code            = e.error_code
      response_code         = e.response_code
      response_page_path    = e.response_page_path
      error_caching_min_ttl = e.error_caching_min_ttl
    }
  ])

  has_aliases = length(var.aliases) > 0

  # The bucket's ARN, computed from the name and not read from `module.bucket`.
  #
  # The policy below goes *into* that module, and reading the ARN back out of it would make
  # the module's input depend on its own output. It happens to be acyclic today, but it
  # stops being so the moment anything the bucket resource needs starts depending on the
  # policy. S3 ARNs contain neither region nor account, so computing it is exact — the same
  # reasoning as `modules/app`.
  bucket_arn = format("arn:%s:s3:::%s", data.aws_partition.current.partition, local.site_name)

  # The bucket stays private: the only access is CloudFront through the OAC, scoped to this
  # distribution with `AWS:SourceArn`. It is the difference between a CDN you can bypass from
  # the S3 endpoint and one you cannot.
  #
  # It is passed to modules/bucket, which merges it with the TLS statements into the single
  # policy S3 allows per bucket. A separate `aws_s3_bucket_policy` here would race with that
  # one and the deployed document would be whichever applied last — either without the OAC
  # access, and the site answers 403 on everything, or without the TLS enforcement.
  #
  # Built with `jsonencode` and not with `aws_iam_policy_document`: the document is then a
  # real value in the tests, where the data source is mocked and would assert nothing.
  bucket_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = ["s3:GetObject"]
      Resource  = [format("%s/*", local.bucket_arn)]
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.this.arn }
      }
    }]
  })
}

data "aws_partition" "current" {}

module "bucket" {
  source = "../bucket"

  prefix = var.prefix
  name   = var.name
  tags   = var.tags

  versioning_enabled = var.bucket_versioning_enabled
  force_destroy      = var.bucket_force_destroy

  # The policy goes through here, so that the bucket keeps a single policy document.
  #
  # There is no cycle: the statement needs the distribution's ARN, the distribution needs the
  # bucket's domain name, and the bucket's policy is a resource of its own — the bucket does
  # not wait for it. The ARN in the statement is computed from the name for the reason above.
  policy_json = local.bucket_policy_json

  # Declared and not derived: the document embeds the ARN of a distribution that does not
  # exist yet, so it is unknown on the first plan, and `policy_json != null` on an unknown
  # value is unknown too.
  attach_policy = true
}

# The distribution is written natively and not through CloudFront's upstream module. That
# module addresses the Origin Access Control by key, and that very indirection produced the
# defect this module exists to correct: a key that matched no OAC, a lookup that found
# nothing, and a distribution that only worked because the bucket was readable by everyone.
resource "aws_cloudfront_origin_access_control" "this" {
  name                              = local.site_name
  description                       = format("OAC for %s", local.site_name)
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = coalesce(var.comment, local.site_name)
  default_root_object = var.default_root_object
  price_class         = var.price_class
  aliases             = var.aliases
  web_acl_id          = var.web_acl_arn
  wait_for_deployment = var.wait_for_deployment
  tags                = local.tags

  origin {
    origin_id                = local.origin_id
    domain_name              = module.bucket.regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = var.allowed_methods
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = var.cache_policy_id
    response_headers_policy_id = var.response_headers_policy_id
  }

  dynamic "custom_error_response" {
    for_each = local.error_responses

    content {
      error_code            = custom_error_response.value.error_code
      response_code         = custom_error_response.value.response_code
      response_page_path    = custom_error_response.value.response_page_path
      error_caching_min_ttl = custom_error_response.value.error_caching_min_ttl
    }
  }

  dynamic "logging_config" {
    for_each = var.logging == null ? [] : [var.logging]

    content {
      bucket          = logging_config.value.bucket
      prefix          = logging_config.value.prefix
      include_cookies = logging_config.value.include_cookies
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.certificate_arn == null
    acm_certificate_arn            = var.certificate_arn
    ssl_support_method             = var.certificate_arn == null ? null : "sni-only"
    minimum_protocol_version       = var.certificate_arn == null ? null : "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# The bucket policy used to be a resource of this module, alongside the one modules/bucket
# creates for the TLS statements: two `aws_s3_bucket_policy` on the same bucket, each
# replacing the other's document. It is now a single policy, and this block hands the old
# resource over to it.
#
# `destroy = false` is the whole point. Destroying it would call DeleteBucketPolicy, which
# removes the entire document — including the statements the surviving resource manages —
# and Terraform does not order a destroy against an update of another resource on the same
# API object. The site could be left with no policy at all, answering 403 on everything,
# until the next apply. Forgetting the resource leaves the deployed document untouched and
# the surviving policy converges on it in the same apply.
removed {
  from = aws_s3_bucket_policy.this

  lifecycle {
    destroy = false
  }
}

resource "aws_route53_record" "this" {
  for_each = var.zone_id == null ? toset([]) : toset(var.aliases)

  zone_id = var.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
