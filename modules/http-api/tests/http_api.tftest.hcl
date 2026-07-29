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
}
