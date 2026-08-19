# The OAC and bucket IDs are assigned by AWS and unknown at plan time: without mocked values
# the comparison between two unknown values stays unknown, and the assertion would verify
# nothing.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_resource "aws_cloudfront_origin_access_control" {
    defaults = {
      id = "E1MOCKOAC00001"
    }
  }

  # The bucket policy is scoped to this ARN: with the generated value the assertion would
  # compare two unknowns and verify nothing.
  mock_resource "aws_cloudfront_distribution" {
    defaults = {
      arn = "arn:aws:cloudfront::111122223333:distribution/E1MOCKDIST00001"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      bucket_regional_domain_name = "acme-prod-web.s3.eu-west-1.amazonaws.com"
    }
  }
}

variables {
  prefix = "acme-prod"
  name   = "web"
}

run "oac_linked_to_the_origin" {
  # `apply` and not `plan`: `mock_resource` values materialize at apply, and in plan they
  # would stay unknown — a comparison between two unknown values is unknown and would verify
  # nothing. With the mocked provider the apply never touches AWS.
  command = apply

  # It is the defect this module corrects: in the previous wiring the origin pointed at an
  # OAC key that did not exist, the lookup found nothing and the distribution only worked
  # because the bucket was public.
  assert {
    condition     = one(aws_cloudfront_distribution.this.origin).origin_access_control_id == aws_cloudfront_origin_access_control.this.id
    error_message = "The origin must reference the OAC the module created, not a symbolic key."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.this.signing_behavior == "always"
    error_message = "The OAC must always sign the requests to the origin."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.origin).domain_name == module.bucket.regional_domain_name
    error_message = "The origin must be the bucket's regional domain name."
  }
}

run "bucket_policy_goes_through_the_bucket_module" {
  # `apply`: the statement is scoped to the distribution's ARN, which is unknown at plan.
  command = apply

  # S3 keeps a single policy document per bucket. This module used to declare its own
  # `aws_s3_bucket_policy` next to the one modules/bucket creates for the TLS statements, and
  # the deployed document was whichever of the two applied last — the site answering 403 on
  # everything, or the TLS enforcement quietly missing.
  assert {
    condition     = module.bucket.policy_json_attached == true
    error_message = "The OAC statement must reach the bucket module, which merges it into the single policy."
  }

  assert {
    condition     = one(jsondecode(output.bucket_policy_json).Statement).Principal.Service == "cloudfront.amazonaws.com"
    error_message = "The only principal allowed to read the bucket must be the CloudFront service."
  }

  assert {
    condition     = one(jsondecode(output.bucket_policy_json).Statement).Action == ["s3:GetObject"]
    error_message = "CloudFront must only be allowed to read the objects."
  }

  assert {
    condition     = one(jsondecode(output.bucket_policy_json).Statement).Resource == ["arn:aws:s3:::acme-prod-web/*"]
    error_message = "The statement must apply to the bucket's objects, on the ARN computed from the name."
  }

  # Without the condition any distribution in any account could read the bucket through an
  # OAC of its own.
  assert {
    condition     = one(jsondecode(output.bucket_policy_json).Statement).Condition.StringEquals["AWS:SourceArn"] == aws_cloudfront_distribution.this.arn
    error_message = "The read access must be scoped to this distribution with AWS:SourceArn."
  }
}

run "https_enforced_and_security_headers" {
  command = plan

  assert {
    condition     = one(aws_cloudfront_distribution.this.default_cache_behavior).viewer_protocol_policy == "redirect-to-https"
    error_message = "HTTP traffic must be redirected to HTTPS."
  }

  # AWS's managed SecurityHeadersPolicy: free headers with no downsides on a static site.
  assert {
    condition     = one(aws_cloudfront_distribution.this.default_cache_behavior).response_headers_policy_id == "67f7725c-6f97-4210-82d7-5512b31e9d03"
    error_message = "The security response headers policy must be enabled by default."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.default_cache_behavior).compress == true
    error_message = "Compression must be enabled."
  }
}

run "default_certificate_without_aliases" {
  command = plan

  assert {
    condition     = one(aws_cloudfront_distribution.this.viewer_certificate).cloudfront_default_certificate == true
    error_message = "Without aliases CloudFront's default certificate must be used."
  }
}

run "acm_certificate_with_aliases" {
  command = plan

  variables {
    aliases         = ["web.acme.example"]
    certificate_arn = "arn:aws:acm:us-east-1:111122223333:certificate/abcd-1234"
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.viewer_certificate).minimum_protocol_version == "TLSv1.2_2021"
    error_message = "With an ACM certificate a modern minimum TLS version must be enforced."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.viewer_certificate).ssl_support_method == "sni-only"
    error_message = "With an ACM certificate the method must be sni-only."
  }
}

run "spa_preset_disabled_by_default" {
  command = plan

  # With the preset on, a missing asset returns the index with a 200 code: on an asset bucket
  # that is a defect the clients never find out about.
  assert {
    condition     = length(output.spa_error_response_codes) == 0
    error_message = "The SPA preset must be disabled by default."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.custom_error_response) == 0
    error_message = "Without the SPA preset and without custom responses there must be no rewriting."
  }
}

run "spa_preset_enabled" {
  command = plan

  variables {
    spa = true
  }

  assert {
    condition     = output.spa_error_response_codes == tolist([403, 404])
    error_message = "The SPA preset must rewrite both the private bucket's 403 and the 404."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.custom_error_response) == 2
    error_message = "The SPA preset must produce two custom responses."
  }
}

run "route53_record_per_alias" {
  command = plan

  variables {
    aliases         = ["web.acme.example", "www.acme.example"]
    certificate_arn = "arn:aws:acm:us-east-1:111122223333:certificate/abcd-1234"
    zone_id         = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = length(aws_route53_record.this) == 2
    error_message = "One record per alias must be created."
  }
}

run "no_records_without_a_zone" {
  command = plan

  variables {
    aliases         = ["web.acme.example"]
    certificate_arn = "arn:aws:acm:us-east-1:111122223333:certificate/abcd-1234"
  }

  assert {
    condition     = length(aws_route53_record.this) == 0
    error_message = "Without zone_id no records must be created: the zone may be managed elsewhere."
  }
}

run "waf_cloudfront" {
  command = plan

  variables {
    web_acl_arn = "arn:aws:wafv2:us-east-1:111122223333:global/webacl/acme-prod/abcd-1234"
  }

  # The WAF lives here and not on http-api because WAFv2 cannot be associated with an HTTP
  # API Gateway: to protect one you need CloudFront in front.
  assert {
    condition     = aws_cloudfront_distribution.this.web_acl_id == "arn:aws:wafv2:us-east-1:111122223333:global/webacl/acme-prod/abcd-1234"
    error_message = "The WebACL must be associated with the distribution."
  }
}
