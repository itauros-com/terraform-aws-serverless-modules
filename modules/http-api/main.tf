locals {
  api_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.api_name })

  # `authorization_type` is derived from the authorizer's type, not declared.
  # In the previous wiring the two had to be written together and could diverge: a route
  # with an authorizer but `authorization_type = "NONE"` is public while looking
  # protected.
  authorization_types = {
    lambda = "CUSTOM"
    jwt    = "JWT"
  }

  routes = {
    for key, r in var.routes : key => {
      authorizer_key     = r.authorizer
      authorization_type = r.authorizer == null ? "NONE" : local.authorization_types[var.authorizers[r.authorizer].type]
      authorization_scopes = (
        r.authorizer != null && var.authorizers[r.authorizer].type == "jwt" ? r.authorization_scopes : []
      )

      detailed_metrics_enabled = r.detailed_metrics_enabled
      throttling_burst_limit   = r.throttling_burst_limit
      throttling_rate_limit    = r.throttling_rate_limit

      integration = merge(
        {
          type                   = "AWS_PROXY"
          integration_type       = "AWS_PROXY"
          connection_type        = "INTERNET"
          method                 = "POST"
          payload_format_version = r.payload_format_version
          uri                    = var.functions[r.function].invoke_arn
        },
        r.timeout_milliseconds != null ? { timeout_milliseconds = r.timeout_milliseconds } : {},
      )
    }
  }

  # A uniform shape with null where the attribute does not apply, instead of two branches
  # with different keys: the two sides of a conditional must have the same type, and the
  # upstream variable has every attribute optional.
  authorizers = {
    for key, a in var.authorizers : key => {
      name            = format("%s-%s", local.api_name, key)
      authorizer_type = a.type == "jwt" ? "JWT" : "REQUEST"

      identity_sources = a.identity_sources

      authorizer_uri                    = a.type == "lambda" ? var.functions[a.function].invoke_arn : null
      authorizer_payload_format_version = a.type == "lambda" ? "2.0" : null
      authorizer_result_ttl_in_seconds  = a.type == "lambda" ? a.result_ttl_in_seconds : null
      enable_simple_responses           = a.type == "lambda" ? a.enable_simple_responses : null

      jwt_configuration = a.type == "jwt" ? {
        issuer   = a.jwt.issuer
        audience = a.jwt.audience
      } : null
    }
  }

  # The functions this API can invoke: the ones integrated by the routes plus the ones used
  # as authorizers, deduplicated. The permission is created by the API because it is the
  # only one that knows the execution ARN — and because that way permission and integration
  # are the same declaration.
  invoked_functions = toset(concat(
    [for r in values(var.routes) : r.function],
    [for a in values(var.authorizers) : a.function if a.type == "lambda"],
  ))

  access_log_format = jsonencode({
    requestId       = "$context.requestId"
    requestTime     = "$context.requestTime"
    httpMethod      = "$context.httpMethod"
    path            = "$context.path"
    routeKey        = "$context.routeKey"
    status          = "$context.status"
    protocol        = "$context.protocol"
    responseLength  = "$context.responseLength"
    responseLatency = "$context.responseLatency"
    domainName      = "$context.domainName"
    sourceIp        = "$context.identity.sourceIp"
    userAgent       = "$context.identity.userAgent"

    # Without these fields a 500 from the API is indistinguishable from a 500 from the
    # application, and a 401 does not say whether the authorizer denied or blew up.
    integrationError  = "$context.integration.error"
    integrationStatus = "$context.integration.integrationStatus"
    authorizerError   = "$context.authorizer.error"
    errorMessage      = "$context.error.message"
    errorResponseType = "$context.error.responseType"
  })
}

module "api" {
  source  = "terraform-aws-modules/apigateway-v2/aws"
  version = "~> 5.0"

  name          = local.api_name
  description   = var.description
  protocol_type = "HTTP"
  tags          = local.tags

  # `null` and not `{}`: upstream emits the CORS block whenever the variable is not null,
  # and an empty block is different from the absence of CORS.
  cors_configuration = var.cors == null ? null : {
    allow_origins     = var.cors.allow_origins
    allow_methods     = var.cors.allow_methods
    allow_headers     = var.cors.allow_headers
    expose_headers    = var.cors.expose_headers
    allow_credentials = var.cors.allow_credentials
    max_age           = var.cors.max_age
  }

  disable_execute_api_endpoint = var.disable_default_endpoint

  authorizers = local.authorizers
  routes      = local.routes

  # The module does not create certificates: validating them has timings and DNS
  # dependencies that do not belong to an API's lifecycle.
  create_domain_name = var.domain != null

  # An empty string and not null: the upstream module computes locals over `domain_name`
  # unguarded, so a null makes the plan fail even when the custom domain is not requested.
  domain_name                 = try(var.domain.name, "")
  domain_name_certificate_arn = try(var.domain.certificate_arn, null)
  create_certificate          = false
  create_domain_records       = try(var.domain.create_records, false)
  hosted_zone_name            = try(var.domain.zone_name, null)

  create_stage = true
  stage_name   = var.stage_name
  stage_tags   = local.tags

  stage_default_route_settings = {
    detailed_metrics_enabled = true
    throttling_burst_limit   = var.throttling.burst_limit
    throttling_rate_limit    = var.throttling.rate_limit
  }

  # Here too `null` and not an object with create_log_group = false: upstream emits the
  # access log block whenever the variable is not null.
  stage_access_log_settings = var.access_logs.enabled ? {
    create_log_group            = var.access_logs.destination_arn == null
    destination_arn             = var.access_logs.destination_arn
    format                      = local.access_log_format
    log_group_retention_in_days = var.access_logs.retention_days
    log_group_kms_key_id        = var.access_logs.kms_key_id
    log_group_tags              = local.tags
  } : null
}

# One permission per function, not per route: a function behind ten routes needs a single
# permission, and `for_each` over a deduplicated set guarantees that.
#
# `/*/*` covers both the invocations from the routes and those from the authorizers, whose
# source ARN has the form `<api-id>/authorizers/<id>`.
resource "aws_lambda_permission" "invoke" {
  for_each = local.invoked_functions

  statement_id  = format("AllowInvokeFrom-%s", local.api_name)
  action        = "lambda:InvokeFunction"
  function_name = var.functions[each.value].arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = format("%s/*/*", module.api.api_execution_arn)

  lifecycle {
    create_before_destroy = true
  }
}
