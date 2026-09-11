data "aws_partition" "current" {}
data "aws_region" "current" {}

# The managed policies are resolved **by name** and not by their well-known IDs.
#
# The IDs are global constants and hardcoding them would work, but a wrong one produces a
# distribution that behaves badly in silence — the wrong cache key, the Authorization header
# dropped — while a wrong name fails at plan with the name in the message.
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

locals {
  cdn_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.cdn_name })

  # ----------------------------------------------------------------------------
  # Origins
  #
  # A bucket origin declares its name, and both the domain and the ARN are derived
  # from it rather than read from the module that creates the bucket.
  #
  # That is what keeps the graph acyclic. The read statement this module produces
  # goes *into* the bucket's policy, so reading anything back out of the bucket
  # module would close the loop — the same reasoning as `modules/site` and as the
  # bucket ↔ queue notifications in `modules/app`. S3 ARNs contain neither region
  # nor account and the regional domain name is a fixed format, so both
  # computations are exact, not approximations.
  # ----------------------------------------------------------------------------
  bucket_origins = { for k, o in var.origins : k => o.bucket if o.bucket != null }
  http_origins   = { for k, o in var.origins : k => o.http if o.http != null }

  bucket_arns = {
    for k, o in local.bucket_origins : k => format("arn:%s:s3:::%s", data.aws_partition.current.partition, o.name)
  }

  bucket_domains = {
    for k, o in local.bucket_origins : k => format("%s.s3.%s.amazonaws.com", o.name, data.aws_region.current.region)
  }

  origins_resolved = merge(
    {
      for k, o in local.bucket_origins : k => {
        is_bucket         = true
        domain_name       = local.bucket_domains[k]
        origin_path       = o.origin_path
        protocol_policy   = null
        ssl_protocols     = null
        read_timeout      = null
        keepalive_timeout = null
        custom_headers    = {}
      }
    },
    {
      for k, o in local.http_origins : k => {
        is_bucket         = false
        domain_name       = o.domain_name
        origin_path       = o.origin_path
        protocol_policy   = o.protocol_policy
        ssl_protocols     = o.ssl_protocols
        read_timeout      = o.read_timeout
        keepalive_timeout = o.keepalive_timeout
        custom_headers    = o.custom_headers
      }
    },
  )

  # ----------------------------------------------------------------------------
  # Presets
  #
  # Four decisions that only make sense together. Taken apart they are four fields
  # anyone can fill in inconsistently, and the inconsistency does not show up in the
  # plan — it shows up as 401 in production.
  # ----------------------------------------------------------------------------
  presets = {
    static = {
      cache_policy_id          = data.aws_cloudfront_cache_policy.optimized.id
      origin_request_policy_id = null
      allowed_methods          = ["GET", "HEAD", "OPTIONS"]
      compress                 = true
    }
    api = {
      cache_policy_id = data.aws_cloudfront_cache_policy.disabled.id
      # Forwards every viewer header except Host — Authorization included, which is
      # the whole point — plus query strings and cookies.
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      # The origin already compresses. Compressing again spends CPU at the edge to
      # produce the same bytes.
      compress = false
    }
    # The signature's parameters are validated at the edge before the cache is
    # consulted, so caching by path is correct: two viewers holding different valid
    # signatures for the same object share one cache entry, which is what you want.
    # CachingOptimized leaves the query string out of the cache key, so the signature
    # does not fragment the cache either.
    private-files = {
      cache_policy_id          = data.aws_cloudfront_cache_policy.optimized.id
      origin_request_policy_id = null
      allowed_methods          = ["GET", "HEAD"]
      compress                 = true
    }
  }

  # The explicit fields override the preset one at a time, each through a comparison with
  # null rather than `coalesce`. `coalesce` would read an explicit `false` as absent, and it
  # raises on an all-null argument list instead of returning null — which is exactly what a
  # preset leaving `origin_request_policy_id` unset produces.
  behavior_fields = {
    for b in concat([merge(var.default_behavior, { path_pattern = null })], var.behaviors) :
    coalesce(b.path_pattern, "*") => {
      path_pattern               = b.path_pattern
      origin                     = b.origin
      cache_policy_id            = b.cache_policy_id != null ? b.cache_policy_id : local.presets[b.preset].cache_policy_id
      origin_request_policy_id   = b.origin_request_policy_id != null ? b.origin_request_policy_id : local.presets[b.preset].origin_request_policy_id
      response_headers_policy_id = b.response_headers_policy_id
      allowed_methods            = b.allowed_methods != null ? b.allowed_methods : local.presets[b.preset].allowed_methods
      viewer_protocol_policy     = b.viewer_protocol_policy
      compress                   = b.compress != null ? b.compress : local.presets[b.preset].compress
      trusted_key_groups         = b.trusted_key_groups
      function_associations      = b.function_associations
    }
  }

  default_behavior_resolved = local.behavior_fields["*"]

  # Rebuilt from `var.behaviors` and not from the map above: a map is ordered by key
  # and the order of the behaviors is semantics, not presentation.
  ordered_behaviors = [for b in var.behaviors : local.behavior_fields[b.path_pattern]]

  # Only GET and HEAD can be cached. Passing the full list of allowed methods as the
  # cached ones is rejected by AWS at apply time.
  cached_methods = ["GET", "HEAD"]

  # ----------------------------------------------------------------------------
  # Key groups
  # ----------------------------------------------------------------------------
  public_keys = merge([
    for gk, g in var.key_groups : {
      for pk, p in g.public_keys : format("%s/%s", gk, pk) => {
        group       = gk
        key         = pk
        encoded_key = p.encoded_key
        comment     = p.comment
      }
    }
  ]...)

  # ----------------------------------------------------------------------------
  # Cross-references
  #
  # Collected rather than raised where they occur: a missing key would otherwise
  # surface as an "Invalid index" naming neither the behavior nor what is wrong with
  # it. The precondition on the `id` output reports them together.
  # ----------------------------------------------------------------------------
  all_behaviors = concat(
    [{ where = "default_behavior", origin = var.default_behavior.origin, trusted_key_groups = var.default_behavior.trusted_key_groups }],
    [for b in var.behaviors : { where = format("behaviors['%s']", b.path_pattern), origin = b.origin, trusted_key_groups = b.trusted_key_groups }],
  )

  used_origins = distinct([for b in local.all_behaviors : b.origin])

  reference_errors = concat(
    [
      for b in local.all_behaviors : format("%s references the origin '%s', which is not in `origins`", b.where, b.origin)
      if !contains(keys(var.origins), b.origin)
    ],
    flatten([
      for b in local.all_behaviors : [
        for g in b.trusted_key_groups : format("%s references the key group '%s', which is not in `key_groups`", b.where, g)
        if !contains(keys(var.key_groups), g)
      ]
    ]),
    [
      for k in keys(var.origins) : format("origins['%s'] is served by no behavior: it would be created and never reached", k)
      if !contains(local.used_origins, k)
    ],
    # The guardrail this module exists for.
    #
    # `trusted_key_groups` belongs to the *behavior*, not to the distribution. A
    # distribution that declares a key group on its default behavior and serves
    # /exports/* from a behavior of its own leaves that path open: anybody who knows
    # an object's key downloads it without a signature. Nothing fails, no log looks
    # wrong, and the bucket is private the whole time.
    [
      for b in local.all_behaviors : format(
        "%s serves the origin '%s', which is declared `require_signed_urls`, with no `trusted_key_groups`: that path would be readable by anyone who knows an object's key",
        b.where, b.origin,
      )
      if contains(keys(local.bucket_origins), b.origin) &&
      try(local.bucket_origins[b.origin].require_signed_urls, false) &&
      length(b.trusted_key_groups) == 0
    ],
  )

  # ----------------------------------------------------------------------------
  # The read statement for each bucket origin.
  #
  # Scoped to this distribution with `AWS:SourceArn`. Without that condition the
  # policy authorizes the CloudFront service principal at large — that is, **any**
  # distribution of **any** AWS account. It is the classic OAC mistake and it leaves
  # no trace: the site works perfectly while being wide open.
  #
  # Built with `jsonencode` and not with `aws_iam_policy_document`, so that the
  # document is a real value in the tests where the data source would be mocked.
  # ----------------------------------------------------------------------------
  # The Sid carries the distribution and the origin, because a bucket can be fronted by more
  # than one distribution and S3 rejects a document with two identical Sids. The composition
  # merges the statements of every distribution into the bucket's single policy, and the
  # names are what keeps them apart there.
  bucket_policy_statements = {
    for k, o in local.bucket_origins : k => {
      Sid       = format("AllowCloudFrontOAC%s", replace(title(replace(format("%s %s", local.cdn_name, k), "/[^0-9A-Za-z]+/", " ")), " ", ""))
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = ["s3:GetObject"]
      Resource  = [format("%s/*", local.bucket_arns[k])]
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.this.arn }
      }
    }
  }

  bucket_policy_json = {
    for k, st in local.bucket_policy_statements : k => jsonencode({
      Version   = "2012-10-17"
      Statement = [st]
    })
  }
}

# ------------------------------------------------------------------------------
# Origin Access Control, one per bucket origin
# ------------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "this" {
  for_each = local.bucket_origins

  name                              = format("%s-%s", local.cdn_name, each.key)
  description                       = format("OAC for %s origin %s", local.cdn_name, each.key)
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ------------------------------------------------------------------------------
# Signed URLs
# ------------------------------------------------------------------------------

resource "aws_cloudfront_public_key" "this" {
  for_each = local.public_keys

  name        = format("%s-%s-%s", local.cdn_name, each.value.group, each.value.key)
  comment     = each.value.comment
  encoded_key = each.value.encoded_key

  # A public key in use by a key group cannot be deleted: without this, rotating one
  # in place fails at apply with a dependency error from AWS.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudfront_key_group" "this" {
  for_each = var.key_groups

  name    = format("%s-%s", local.cdn_name, each.key)
  comment = each.value.comment

  items = [
    for pk in keys(each.value.public_keys) : aws_cloudfront_public_key.this[format("%s/%s", each.key, pk)].id
  ]
}

# ------------------------------------------------------------------------------
# Distribution
#
# Written natively rather than through CloudFront's upstream module, for the reason
# `modules/site` gives: that module addresses the Origin Access Control by key, and that
# indirection is the very defect these modules exist to correct.
# ------------------------------------------------------------------------------

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = coalesce(var.comment, local.cdn_name)
  default_root_object = var.default_root_object
  price_class         = var.price_class
  aliases             = var.aliases
  web_acl_id          = var.web_acl_arn
  wait_for_deployment = var.wait_for_deployment
  tags                = local.tags

  dynamic "origin" {
    for_each = local.origins_resolved

    content {
      origin_id                = origin.key
      domain_name              = origin.value.domain_name
      origin_path              = origin.value.origin_path
      origin_access_control_id = origin.value.is_bucket ? aws_cloudfront_origin_access_control.this[origin.key].id : null

      dynamic "custom_origin_config" {
        for_each = origin.value.is_bucket ? [] : [origin.value]

        content {
          http_port                = 80
          https_port               = 443
          origin_protocol_policy   = custom_origin_config.value.protocol_policy
          origin_ssl_protocols     = custom_origin_config.value.ssl_protocols
          origin_read_timeout      = custom_origin_config.value.read_timeout
          origin_keepalive_timeout = custom_origin_config.value.keepalive_timeout
        }
      }

      dynamic "custom_header" {
        for_each = origin.value.custom_headers

        content {
          name  = custom_header.key
          value = custom_header.value
        }
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = local.default_behavior_resolved.origin
    viewer_protocol_policy = local.default_behavior_resolved.viewer_protocol_policy
    allowed_methods        = local.default_behavior_resolved.allowed_methods
    cached_methods         = local.cached_methods
    compress               = local.default_behavior_resolved.compress

    cache_policy_id            = local.default_behavior_resolved.cache_policy_id
    origin_request_policy_id   = local.default_behavior_resolved.origin_request_policy_id
    response_headers_policy_id = local.default_behavior_resolved.response_headers_policy_id

    # Filtered, like the cross-references in `modules/app`. It is not a silent fallback: a
    # key group that does not exist is in `reference_errors` and stops the plan from the
    # precondition, which names the behavior. Without the filter the lookup raises first,
    # with an "Invalid index" that names neither.
    trusted_key_groups = [
      for g in local.default_behavior_resolved.trusted_key_groups : aws_cloudfront_key_group.this[g].id
      if contains(keys(var.key_groups), g)
    ]

    dynamic "function_association" {
      for_each = local.default_behavior_resolved.function_associations

      content {
        event_type   = function_association.key
        function_arn = function_association.value
      }
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.ordered_behaviors

    content {
      path_pattern           = ordered_cache_behavior.value.path_pattern
      target_origin_id       = ordered_cache_behavior.value.origin
      viewer_protocol_policy = ordered_cache_behavior.value.viewer_protocol_policy
      allowed_methods        = ordered_cache_behavior.value.allowed_methods
      cached_methods         = local.cached_methods
      compress               = ordered_cache_behavior.value.compress

      cache_policy_id            = ordered_cache_behavior.value.cache_policy_id
      origin_request_policy_id   = ordered_cache_behavior.value.origin_request_policy_id
      response_headers_policy_id = ordered_cache_behavior.value.response_headers_policy_id

      trusted_key_groups = [
        for g in ordered_cache_behavior.value.trusted_key_groups : aws_cloudfront_key_group.this[g].id
        if contains(keys(var.key_groups), g)
      ]

      dynamic "function_association" {
        for_each = ordered_cache_behavior.value.function_associations

        content {
          event_type   = function_association.key
          function_arn = function_association.value
        }
      }
    }
  }

  dynamic "custom_error_response" {
    for_each = var.custom_error_responses

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
