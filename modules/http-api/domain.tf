# The custom domain, created here and not by upstream: upstream disables the `execute-api`
# endpoint whenever it creates a domain, and an API whose clients still call the AWS URL
# could not get a domain without cutting them off. The resources are the ones upstream
# created, with the same arguments, so that an API that had its domain from upstream moves
# here without changes.
#
# The module does not create certificates: validating them has timings and DNS
# dependencies that do not belong to an API's lifecycle.
resource "aws_apigatewayv2_domain_name" "this" {
  count = var.domain == null ? 0 : 1

  domain_name = var.domain.name

  domain_name_configuration {
    certificate_arn = var.domain.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = local.tags
}

resource "aws_apigatewayv2_api_mapping" "this" {
  count = var.domain == null ? 0 : 1

  api_id      = module.api.api_id
  domain_name = aws_apigatewayv2_domain_name.this[0].id
  stage       = module.api.stage_id
}

data "aws_route53_zone" "this" {
  count = var.domain != null && try(var.domain.create_records, false) ? 1 : 0

  name = var.domain.zone_name
}

# Keyed by record type alone: upstream's keys contain the domain name, and a `moved` block
# cannot name them, so its records are moved by hand (see the CHANGELOG for 0.6.0).
resource "aws_route53_record" "this" {
  for_each = var.domain != null && try(var.domain.create_records, false) ? toset(["A", "AAAA"]) : toset([])

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain.name
  type    = each.key

  alias {
    name                   = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

moved {
  from = module.api.aws_apigatewayv2_domain_name.this[0]
  to   = aws_apigatewayv2_domain_name.this[0]
}

moved {
  from = module.api.aws_apigatewayv2_api_mapping.this[0]
  to   = aws_apigatewayv2_api_mapping.this[0]
}
