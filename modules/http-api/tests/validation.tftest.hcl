mock_provider "aws" {}

variables {
  prefix = "acme-prod"
  name   = "api"

  functions = {
    users = {
      arn        = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-users"
      invoke_arn = "arn:aws:apigateway:eu-west-1:lambda:path/2015-03-31/functions/arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-users/invocations"
    }
  }
}

run "malformed_route_key" {
  command = plan

  variables {
    routes = {
      "/users" = { function = "users" }
    }
  }

  expect_failures = [var.routes]
}

run "nonexistent_http_method" {
  command = plan

  variables {
    routes = {
      "FETCH /users" = { function = "users" }
    }
  }

  expect_failures = [var.routes]
}

run "route_towards_a_nonexistent_function" {
  command = plan

  variables {
    routes = {
      "GET /users" = { function = "utenti" }
    }
  }

  expect_failures = [var.routes]
}

run "lambda_authorizer_without_a_function" {
  command = plan

  variables {
    authorizers = {
      custom = { type = "lambda" }
    }
    routes = { "GET /users" = { function = "users", authorizer = "custom" } }
  }

  expect_failures = [var.authorizers]
}

run "jwt_authorizer_without_configuration" {
  command = plan

  variables {
    authorizers = {
      jwt = { type = "jwt" }
    }
    routes = { "GET /users" = { function = "users", authorizer = "jwt" } }
  }

  expect_failures = [var.authorizers]
}

run "authorizer_of_a_nonexistent_type" {
  command = plan

  variables {
    authorizers = {
      custom = { type = "cognito", function = "users" }
    }
    routes = { "GET /users" = { function = "users", authorizer = "custom" } }
  }

  expect_failures = [var.authorizers]
}

run "cached_authorizer_without_an_identity_source" {
  command = plan

  variables {
    authorizers = {
      custom = {
        type                  = "lambda"
        function              = "users"
        result_ttl_in_seconds = 300
        identity_sources      = []
      }
    }
    routes = { "GET /users" = { function = "users", authorizer = "custom" } }
  }

  # With a TTL greater than zero and no identity source the authorizer's answer is cached
  # for all requests indiscriminately: whoever gets through once gets through for everyone
  # until it expires.
  expect_failures = [var.authorizers]
}

run "cors_with_credentials_and_a_wildcard" {
  command = plan

  variables {
    routes = { "GET /users" = { function = "users" } }
    cors = {
      allow_origins     = ["*"]
      allow_credentials = true
    }
  }

  # Browsers reject this combination: better to learn it from the plan than from the
  # frontend.
  expect_failures = [var.cors]
}

run "custom_domain_without_a_certificate" {
  command = plan

  variables {
    routes = { "GET /users" = { function = "users" } }
    domain = { name = "api.acme.example" }
  }

  expect_failures = [var.domain]
}

run "route53_records_without_a_zone" {
  command = plan

  variables {
    routes = { "GET /users" = { function = "users" } }
    domain = {
      name            = "api.acme.example"
      certificate_arn = "arn:aws:acm:eu-west-1:111122223333:certificate/abcd"
      create_records  = true
    }
  }

  expect_failures = [var.domain]
}
