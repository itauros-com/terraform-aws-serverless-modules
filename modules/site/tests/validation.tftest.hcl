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
}

variables {
  prefix = "acme-prod"
  name   = "web"
}

run "certificate_outside_us_east_1" {
  command = plan

  variables {
    aliases         = ["web.acme.example"]
    certificate_arn = "arn:aws:acm:eu-west-1:111122223333:certificate/abcd-1234"
  }

  # CloudFront does not accept certificates from other regions, and the error it returns does
  # not say so.
  expect_failures = [var.certificate_arn]
}

run "regional_webacl_on_cloudfront" {
  command = plan

  variables {
    web_acl_arn = "arn:aws:wafv2:eu-west-1:111122223333:regional/webacl/acme-prod/abcd-1234"
  }

  expect_failures = [var.web_acl_arn]
}

run "aliases_without_a_certificate" {
  command = plan

  variables {
    aliases = ["web.acme.example"]
  }

  # Without a certificate CloudFront only serves its own domain: the requests on the aliases
  # would fail in TLS.
  expect_failures = [output.distribution_id]
}

run "zone_without_aliases" {
  command = plan

  variables {
    zone_id = "Z0123456789ABCDEFGHIJ"
  }

  expect_failures = [output.distribution_id]
}

run "nonexistent_price_class" {
  command = plan

  variables {
    price_class = "PriceClass_50"
  }

  expect_failures = [var.price_class]
}
