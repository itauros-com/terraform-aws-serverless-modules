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
}

module "bucket" {
  source = "../bucket"

  prefix = var.prefix
  name   = var.name
  tags   = var.tags

  versioning_enabled = var.bucket_versioning_enabled
  force_destroy      = var.bucket_force_destroy

  # The policy does not go through here: it has to reference the distribution's ARN, which
  # in turn needs the bucket's domain name. Passing it as an input would create a cycle
  # between the two modules, so the policy is a separate resource further down this file.
  policy_json = null
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

# The bucket stays private: the only access is CloudFront through the OAC, scoped to this
# distribution with `AWS:SourceArn`. It is the difference between a CDN you can bypass from
# the S3 endpoint and one you cannot.
data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${module.bucket.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = module.bucket.name
  policy = data.aws_iam_policy_document.bucket.json
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
