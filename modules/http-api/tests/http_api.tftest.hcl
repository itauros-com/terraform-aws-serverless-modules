mock_provider "aws" {}

variables {
  prefix = "acme-prod"
  name   = "api"

  functions = {
    files = {
      arn        = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-files"
      invoke_arn = "arn:aws:apigateway:eu-west-1:lambda:path/2015-03-31/functions/arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-files/invocations"
      name       = "acme-prod-files"
    }
    users = {
      arn        = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-users"
      invoke_arn = "arn:aws:apigateway:eu-west-1:lambda:path/2015-03-31/functions/arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-users/invocations"
      name       = "acme-prod-users"
    }
    authorizer = {
      arn        = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-authorizer"
      invoke_arn = "arn:aws:apigateway:eu-west-1:lambda:path/2015-03-31/functions/arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-authorizer/invocations"
      name       = "acme-prod-authorizer"
    }
  }
}

run "authorization_type_derived_from_the_authorizer" {
  command = plan

  variables {
    authorizers = {
      custom = { type = "lambda", function = "authorizer" }
      jwt = {
        type = "jwt"
        jwt  = { issuer = "https://acme.eu.auth0.com/", audience = ["https://api.acme.example"] }
      }
    }

    routes = {
      "ANY /files"          = { function = "files", authorizer = "custom" }
      "ANY /files/{proxy+}" = { function = "files", authorizer = "custom" }
      "GET /users"          = { function = "users", authorizer = "jwt" }
      "GET /health"         = { function = "users" }
    }
  }

  # In the previous wiring `authorization_type` had to be written by hand next to the
  # authorizer's key: a route with an authorizer and type NONE is public while looking
  # protected. Here the type is derived and cannot diverge.
  assert {
    condition = output.route_authorization == {
      "ANY /files"          = "CUSTOM"
      "ANY /files/{proxy+}" = "CUSTOM"
      "GET /users"          = "JWT"
      "GET /health"         = "NONE"
    }
    error_message = "The authorization type must be derived from the named authorizer's type."
  }
}

run "one_permission_per_function_not_per_route" {
  command = plan

  variables {
    authorizers = {
      custom = { type = "lambda", function = "authorizer" }
    }

    routes = {
      "ANY /files"          = { function = "files", authorizer = "custom" }
      "ANY /files/{proxy+}" = { function = "files", authorizer = "custom" }
      "GET /users"          = { function = "users" }
    }
  }

  # `files` appears in two routes but must receive a single permission, and the authorizer
  # must be included even though it is not the target of any route.
  assert {
    condition     = output.invoked_function_keys == tolist(["authorizer", "files", "users"])
    error_message = "The invocable functions must be deduplicated and include the authorizers."
  }

  assert {
    condition     = length(aws_lambda_permission.invoke) == 3
    error_message = "There must be one permission per distinct function, not per route."
  }

  assert {
    condition     = aws_lambda_permission.invoke["files"].principal == "apigateway.amazonaws.com"
    error_message = "The permission's principal must be API Gateway."
  }

  assert {
    condition     = aws_lambda_permission.invoke["files"].function_name == "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-files"
    error_message = "The permission must use the function's ARN, not the invoke_arn."
  }
}

run "permission_statement_id_derived_or_declared" {
  command = plan

  variables {
    routes = {
      "ANY /files" = { function = "files" }
    }
  }

  assert {
    condition     = aws_lambda_permission.invoke["files"].statement_id == "AllowInvokeFrom-acme-prod-api"
    error_message = "Without permission_statement_id the id must be derived from the API's name."
  }
}

run "permission_statement_id_of_an_adopted_api" {
  command = plan

  variables {
    permission_statement_id = "AllowAPIGatewaySample"
    routes = {
      "ANY /files" = { function = "files" }
    }
  }

  # The id the existing permissions have: moved into the module's addresses, they are not
  # replaced.
  assert {
    condition     = aws_lambda_permission.invoke["files"].statement_id == "AllowAPIGatewaySample"
    error_message = "A declared permission_statement_id must replace the derived one."
  }
}

run "authorizer_name_derived_or_declared" {
  command = plan

  variables {
    authorizers = {
      custom  = { type = "lambda", function = "authorizer" }
      adopted = { type = "lambda", function = "authorizer", name = "got-dev-authorizer" }
    }
    routes = {
      "ANY /files" = { function = "files", authorizer = "custom" }
      "GET /users" = { function = "users", authorizer = "adopted" }
    }
  }

  assert {
    condition     = local.authorizers["custom"].name == "acme-prod-api-custom"
    error_message = "Without `name` the authorizer's name must be derived from the API's and the key."
  }

  # An authorizer adopted from an existing API keeps the name it has.
  assert {
    condition     = local.authorizers["adopted"].name == "got-dev-authorizer"
    error_message = "A declared `name` must replace the derived one."
  }
}

run "jwt_authorizer_without_a_lambda" {
  command = plan

  variables {
    authorizers = {
      jwt = {
        type = "jwt"
        jwt  = { issuer = "https://acme.eu.auth0.com/", audience = ["https://api.acme.example"] }
      }
    }

    routes = {
      "GET /users" = { function = "users", authorizer = "jwt" }
    }
  }

  # A JWT authorizer invokes nothing: it must not appear among the authorized functions.
  assert {
    condition     = output.invoked_function_keys == tolist(["users"])
    error_message = "A JWT authorizer must not produce invocation permissions."
  }
}

run "api_without_routes" {
  command = plan

  assert {
    condition     = length(aws_lambda_permission.invoke) == 0
    error_message = "Without routes no invocation permission must exist."
  }

  assert {
    condition     = length(output.route_authorization) == 0
    error_message = "Without routes the authorization map must be empty."
  }
}

run "alarms_enabled_by_default" {
  command = plan

  variables {
    routes = {
      "GET /health" = { function = "users" }
    }
  }

  assert {
    condition     = length(output.alarm_arns) == 2
    error_message = "There must be two alarms: server errors and latency."
  }

  # On HTTP APIs the metric is called `5xx`. `5XXError` belongs to the REST APIs and would
  # produce an alarm permanently in INSUFFICIENT_DATA.
  assert {
    condition     = aws_cloudwatch_metric_alarm.server_errors[0].metric_name == "5xx"
    error_message = "The HTTP APIs' server error metric is '5xx'."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.latency[0].extended_statistic == "p99"
    error_message = "The latency alarm must use the p99, not the average."
  }
}

run "alarms_can_be_disabled" {
  command = plan

  variables {
    routes = { "GET /health" = { function = "users" } }
    alarms = { enabled = false }
  }

  assert {
    condition     = length(output.alarm_arns) == 0
    error_message = "alarms.enabled = false must create no alarm."
  }
}

run "without_a_custom_domain" {
  command = plan

  variables {
    routes = { "GET /health" = { function = "users" } }
  }

  assert {
    condition     = output.domain_name == null
    error_message = "Without a custom domain the domain output must be null."
  }

  assert {
    condition     = output.default_endpoint_disabled == false
    error_message = "Without a custom domain the execute-api endpoint must stay on."
  }
}

run "a_custom_domain_disables_the_default_endpoint" {
  command = plan

  variables {
    routes = { "GET /health" = { function = "users" } }
    domain = {
      name            = "api.acme.example"
      certificate_arn = "arn:aws:acm:eu-west-1:111122223333:certificate/abc"
      create_records  = false
    }
  }

  assert {
    condition     = output.default_endpoint_disabled == true
    error_message = "With a custom domain and no disable_default_endpoint the execute-api endpoint must be disabled."
  }

  assert {
    condition     = length(aws_apigatewayv2_domain_name.this) == 1 && length(aws_apigatewayv2_api_mapping.this) == 1
    error_message = "A custom domain must create the domain name and its API mapping in this module."
  }

  assert {
    condition     = length(aws_route53_record.this) == 0
    error_message = "create_records = false must create no record."
  }
}

# Upstream forces the endpoint off whenever it creates the domain: an API whose clients
# still call the AWS URL could not get a domain without cutting them off.
run "a_custom_domain_can_keep_the_default_endpoint" {
  command = plan

  variables {
    routes = { "GET /health" = { function = "users" } }
    domain = {
      name            = "api.acme.example"
      certificate_arn = "arn:aws:acm:eu-west-1:111122223333:certificate/abc"
      create_records  = false
    }
    disable_default_endpoint = false
  }

  assert {
    condition     = output.default_endpoint_disabled == false
    error_message = "disable_default_endpoint = false must keep the execute-api endpoint on next to a custom domain."
  }
}

run "a_custom_domain_with_records" {
  command = plan

  variables {
    routes = { "GET /health" = { function = "users" } }
    domain = {
      name            = "api.acme.example"
      certificate_arn = "arn:aws:acm:eu-west-1:111122223333:certificate/abc"
      zone_name       = "acme.example"
    }
  }

  assert {
    condition     = toset(keys(aws_route53_record.this)) == toset(["A", "AAAA"])
    error_message = "With create_records the domain must get an A and an AAAA alias record."
  }

  assert {
    condition     = aws_route53_record.this["A"].name == "api.acme.example"
    error_message = "The records must be named after the domain."
  }
}
