mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_data "aws_region" {
    defaults = {
      name   = "eu-west-1"
      region = "eu-west-1"
    }
  }

  mock_data "aws_cloudfront_cache_policy" {
    defaults = { id = "mock-cache-policy" }
  }

  mock_data "aws_cloudfront_origin_request_policy" {
    defaults = { id = "mock-origin-request-policy" }
  }
}

variables {
  prefix = "acme-prod"
  name   = "edge"

  origins = {
    api = { http = { domain_name = "aaaa1111.execute-api.eu-west-1.amazonaws.com" } }
  }

  default_behavior = { origin = "api", preset = "api" }
}

# ------------------------------------------------------------------------------
# Origins
# ------------------------------------------------------------------------------

run "origin_with_neither_bucket_nor_http" {
  command = plan

  variables {
    origins = {
      api = {}
    }
  }

  expect_failures = [var.origins]
}

run "origin_with_both_bucket_and_http" {
  command = plan

  variables {
    origins = {
      api = {
        bucket = { name = "acme-prod-api" }
        http   = { domain_name = "aaaa1111.execute-api.eu-west-1.amazonaws.com" }
      }
    }
  }

  expect_failures = [var.origins]
}

run "unknown_origin_in_a_behavior" {
  command = plan

  variables {
    default_behavior = { origin = "nope" }
  }

  # Routed to the precondition so that the message names the behavior and the key. Left to
  # surface on its own it would be an "Invalid index" on a `dynamic` block.
  expect_failures = [output.distribution_id]
}

run "origin_reached_by_no_behavior" {
  command = plan

  variables {
    origins = {
      api = { http = { domain_name = "aaaa1111.execute-api.eu-west-1.amazonaws.com" } }
      # Almost always a typo in the key used by the behavior, and the symptom is an origin
      # that exists in the console and never serves a byte.
      legacy = { http = { domain_name = "cccc3333.execute-api.eu-west-1.amazonaws.com" } }
    }
  }

  expect_failures = [output.distribution_id]
}

# ------------------------------------------------------------------------------
# Behaviors
# ------------------------------------------------------------------------------

run "two_behaviors_with_the_same_path" {
  command = plan

  variables {
    behaviors = [
      { path_pattern = "/v1/*", origin = "api" },
      { path_pattern = "/v1/*", origin = "api" },
    ]
  }

  # CloudFront stops at the first match: the second is dead code, and nothing says so.
  expect_failures = [var.behaviors]
}

run "unknown_preset" {
  command = plan

  variables {
    default_behavior = { origin = "api", preset = "cached" }
  }

  expect_failures = [var.default_behavior]
}

run "function_association_on_an_unknown_event" {
  command = plan

  variables {
    behaviors = [
      {
        path_pattern          = "/v1/*"
        origin                = "api"
        function_associations = { "origin-request" = "arn:aws:cloudfront::111122223333:function/rewrite" }
      },
    ]
  }

  # `origin-request` and `origin-response` belong to Lambda@Edge, not to CloudFront
  # Functions, and the distinction is easy to miss.
  expect_failures = [var.behaviors]
}

# ------------------------------------------------------------------------------
# Signed URLs — the guardrail this module exists for
# ------------------------------------------------------------------------------

run "private_origin_served_without_a_key_group" {
  command = plan

  variables {
    origins = {
      exports = { bucket = { name = "acme-prod-exports", require_signed_urls = true } }
    }
    default_behavior = { origin = "exports", preset = "private-files" }
  }

  # The bucket is private the whole time and nothing in the plan looks wrong, but the path
  # is served to anyone who knows an object's key. It is the failure the module exists to
  # make impossible.
  expect_failures = [output.distribution_id]
}

run "private_origin_open_on_one_behavior_only" {
  command = plan

  variables {
    origins = {
      exports = { bucket = { name = "acme-prod-exports", require_signed_urls = true } }
    }
    key_groups = {
      downloads = { public_keys = { current = { encoded_key = "MOCK" } } }
    }
    default_behavior = {
      origin             = "exports"
      preset             = "private-files"
      trusted_key_groups = ["downloads"]
    }
    behaviors = [
      # The key group on the default behavior protects nothing here: this path has a
      # behavior of its own and CloudFront never reaches the default one for it.
      { path_pattern = "/public/*", origin = "exports", preset = "private-files" },
    ]
  }

  expect_failures = [output.distribution_id]
}

run "unknown_key_group" {
  command = plan

  variables {
    default_behavior = { origin = "api", trusted_key_groups = ["nope"] }
  }

  expect_failures = [output.distribution_id]
}

run "key_group_with_no_public_key" {
  command = plan

  variables {
    key_groups = {
      downloads = { public_keys = {} }
    }
  }

  # It accepts no signature: every request to a behavior naming it is refused, and the
  # configuration looks complete.
  expect_failures = [var.key_groups]
}

# ------------------------------------------------------------------------------
# Distribution
# ------------------------------------------------------------------------------

run "certificate_outside_us_east_1" {
  command = plan

  variables {
    aliases         = ["edge.example.com"]
    certificate_arn = "arn:aws:acm:eu-west-1:111122223333:certificate/abc"
  }

  # CloudFront refuses it at apply, with an error that does not mention the region.
  expect_failures = [var.certificate_arn]
}

run "aliases_without_a_certificate" {
  command = plan

  variables {
    aliases = ["edge.example.com"]
  }

  # AWS accepts the configuration and serves the aliases with the default certificate,
  # valid for *.cloudfront.net and nothing else: every viewer gets a TLS error.
  expect_failures = [output.distribution_id]
}

run "zone_without_aliases" {
  command = plan

  variables {
    zone_id = "Z0123456789ABCDEFGHIJ"
  }

  expect_failures = [output.distribution_id]
}

run "regional_web_acl" {
  command = plan

  variables {
    web_acl_arn = "arn:aws:wafv2:eu-west-1:111122223333:regional/webacl/acme/abc"
  }

  expect_failures = [var.web_acl_arn]
}
