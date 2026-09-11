mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name   = "eu-west-1"
      region = "eu-west-1"
    }
  }

  mock_data "aws_cloudfront_cache_policy" {
    defaults = {
      id = "mock-cache-policy"
    }
  }

  mock_data "aws_cloudfront_origin_request_policy" {
    defaults = {
      id = "mock-origin-request-policy"
    }
  }

  # The buckets' statement is scoped to this ARN. With the generated value the assertion
  # would compare two unknowns and verify nothing.
  mock_resource "aws_cloudfront_distribution" {
    defaults = {
      arn = "arn:aws:cloudfront::111122223333:distribution/E1MOCKDIST00001"
    }
  }
}

# The shape of this configuration is the one the library grew out of: one domain that
# aggregates two HTTP APIs by path, and one that serves two private buckets whose objects
# must not be reachable without a signature.
variables {
  prefix = "acme-prod"
  name   = "edge"

  certificate_arn = "arn:aws:acm:us-east-1:111122223333:certificate/abc"
  aliases         = ["edge.example.com"]

  origins = {
    api = {
      http = { domain_name = "aaaa1111.execute-api.eu-west-1.amazonaws.com" }
    }
    billing = {
      http = {
        domain_name    = "bbbb2222.execute-api.eu-west-1.amazonaws.com"
        read_timeout   = 60
        custom_headers = { "X-From-CloudFront" = "acme-prod" }
      }
    }
    exports = {
      bucket = { name = "acme-prod-exports", require_signed_urls = true }
    }
  }

  key_groups = {
    downloads = {
      public_keys = {
        "2026-09" = { encoded_key = "-----BEGIN PUBLIC KEY-----\nMOCK\n-----END PUBLIC KEY-----" }
      }
    }
  }

  default_behavior = { origin = "api", preset = "api" }

  behaviors = [
    { path_pattern = "/billing/*", origin = "billing", preset = "api" },
    {
      path_pattern       = "/exports/*"
      origin             = "exports"
      preset             = "private-files"
      trusted_key_groups = ["downloads"]
    },
  ]
}

run "the_whole_distribution_plans" {
  command = plan

  assert {
    condition     = length(aws_cloudfront_distribution.this.ordered_cache_behavior) == 2
    error_message = "Both ordered behaviors must be created."
  }

  # One per bucket origin, and none for the HTTP ones.
  assert {
    condition     = length(aws_cloudfront_origin_access_control.this) == 1
    error_message = "An OAC must be created for the bucket origin and only for it."
  }
}

run "bucket_origin_derived_from_the_name" {
  command = plan

  # Derived and not read from the module that creates the bucket: that is what keeps the
  # caller's graph acyclic.
  assert {
    condition     = local.bucket_domains["exports"] == "acme-prod-exports.s3.eu-west-1.amazonaws.com"
    error_message = "The regional domain name must be derived from the bucket's name and the region."
  }

  assert {
    condition     = local.bucket_arns["exports"] == "arn:aws:s3:::acme-prod-exports"
    error_message = "The bucket's ARN must be derived from the name: S3 ARNs carry neither region nor account."
  }
}

run "behavior_order_is_preserved" {
  command = plan

  # A map would be ordered by key and `/billing/*` would end up before `/exports/*` by
  # accident rather than by declaration. CloudFront stops at the first match, so the order
  # is semantics.
  assert {
    condition     = local.ordered_behaviors[0].path_pattern == "/billing/*"
    error_message = "The behaviors must keep the order they were declared in."
  }

  assert {
    condition     = local.ordered_behaviors[1].path_pattern == "/exports/*"
    error_message = "The behaviors must keep the order they were declared in."
  }
}

run "the_api_preset_forwards_authorization" {
  command = plan

  # The failure this preset exists for: with the static cache policy the Authorization
  # header never reaches the origin and every request answers 401, with nothing saying why.
  #
  # Asserted on the **name** the data source looks up and not on the ID it returns: the
  # mocked provider hands back no ID for these two data sources, at plan or at apply, so an
  # assertion on the ID would compare null with null and pass for the wrong reason. The name
  # is the input, and a wrong one is exactly how this breaks — a managed policy that exists
  # but forwards something else.
  assert {
    condition     = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.name == "Managed-AllViewerExceptHostHeader"
    error_message = "The `api` preset must resolve the managed policy that forwards every viewer header except Host."
  }

  assert {
    condition     = data.aws_cloudfront_cache_policy.disabled.name == "Managed-CachingDisabled"
    error_message = "The `api` preset must not cache: an API served from the cache answers with another viewer's data."
  }

  assert {
    condition     = contains(local.default_behavior_resolved.allowed_methods, "DELETE")
    error_message = "The `api` preset must allow the write methods."
  }

  # The origin already compresses: doing it again spends CPU at the edge for the same bytes.
  assert {
    condition     = local.default_behavior_resolved.compress == false
    error_message = "The `api` preset must not compress."
  }
}

run "the_static_preset_is_the_default" {
  command = plan

  variables {
    default_behavior = { origin = "api" }
    behaviors        = []
    origins = {
      api = { http = { domain_name = "aaaa1111.execute-api.eu-west-1.amazonaws.com" } }
    }
    key_groups = {}
  }

  # The difference from `api`: no origin request policy at all. This one is assertable,
  # because null is what the preset writes, not what the mocked provider returns.
  assert {
    condition     = local.presets.static.origin_request_policy_id == null
    error_message = "The `static` preset attaches no origin request policy."
  }

  assert {
    condition     = local.default_behavior_resolved.compress == true
    error_message = "The `static` preset must compress."
  }
}

run "an_explicit_field_overrides_the_preset" {
  command = plan

  variables {
    default_behavior = {
      origin          = "api"
      preset          = "api"
      cache_policy_id = "a-policy-of-my-own"
      compress        = true
    }
    behaviors = []
    origins = {
      api = { http = { domain_name = "aaaa1111.execute-api.eu-west-1.amazonaws.com" } }
    }
    key_groups = {}
  }

  assert {
    condition     = local.default_behavior_resolved.cache_policy_id == "a-policy-of-my-own"
    error_message = "An explicit cache policy must win over the preset's."
  }

  # `compress` goes through a comparison with null and not through `coalesce`, which would
  # read an explicit `false` as absent — and here an explicit `true` over a preset `false`.
  assert {
    condition     = local.default_behavior_resolved.compress == true
    error_message = "An explicit `compress` must win over the preset's, in both directions."
  }
}

run "the_oac_statement_is_scoped_to_this_distribution" {
  # `apply` and not `plan`: the statement embeds the distribution's ARN, which is unknown
  # until it exists. With the mocked provider the apply never touches AWS.
  command = apply

  # Without the `AWS:SourceArn` condition the policy authorizes the CloudFront service
  # principal at large — any distribution of any AWS account. The mistake leaves no trace:
  # the bucket serves correctly the whole time.
  assert {
    condition     = strcontains(output.bucket_policy_json["exports"], "AWS:SourceArn")
    error_message = "The OAC statement must be scoped to this distribution's ARN."
  }

  assert {
    condition     = strcontains(output.bucket_policy_json["exports"], "arn:aws:s3:::acme-prod-exports/*")
    error_message = "The statement must grant reads on the bucket's objects."
  }

  # Only the bucket origins: an HTTP origin has no policy to attach anywhere.
  assert {
    condition     = length(output.bucket_policy_json) == 1
    error_message = "Only the bucket origins produce a policy."
  }
}

run "the_resolved_behaviors_are_readable" {
  command = plan

  assert {
    condition     = output.behaviors[0].path_pattern == "(default)"
    error_message = "The default behavior comes first, where CloudFront evaluates it last but reads first."
  }

  assert {
    condition     = output.behaviors[2].signed == true
    error_message = "A behavior with a key group must be reported as signed."
  }

  assert {
    condition     = output.behaviors[1].signed == false
    error_message = "A behavior with no key group must be reported as unsigned."
  }
}

run "one_public_key_per_group_entry" {
  command = plan

  assert {
    condition     = length(aws_cloudfront_public_key.this) == 1
    error_message = "A public key must be created for each entry of each group."
  }

  assert {
    condition     = length(aws_cloudfront_key_group.this) == 1
    error_message = "A key group must be created for each declared group."
  }
}
