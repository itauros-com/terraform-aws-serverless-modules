# http-api

An HTTP API Gateway with routes, authorizers, CORS, structured access logs, throttling, a custom domain and
alarms. It wraps [`terraform-aws-modules/apigateway-v2/aws`](https://github.com/terraform-aws-modules/terraform-aws-apigateway-v2)
`~> 5.0`.

## Usage

```hcl
module "api" {
  source = "…//modules/http-api"

  prefix = "acme-prod"
  name   = "api"

  functions = {
    files      = module.files.integration_entry
    users      = module.users.integration_entry
    authorizer = module.authorizer.integration_entry
  }

  authorizers = {
    custom = { type = "lambda", function = "authorizer" }
  }

  routes = {
    "ANY /files"          = { function = "files", authorizer = "custom" }
    "ANY /files/{proxy+}" = { function = "files", authorizer = "custom" }
    "GET /users"          = { function = "users", authorizer = "custom" }
    "GET /health"         = { function = "users" }
  }

  cors = {
    allow_origins = ["https://app.acme.example"]
    allow_methods = ["GET", "POST", "PUT", "DELETE"]
  }
}
```

## `authorization_type` is derived, not declared

In the wiring this library grew out of, a protected route was written like this:

```hcl
"ANY /files" = {
  authorizer_key     = "authorizer"
  authorization_type = "CUSTOM"     # ← redundant, and can diverge
}
```

Two fields that must agree, maintained by hand. A route with `authorizer_key` set and
`authorization_type = "NONE"` is **public while looking protected**, and nothing reports it.

Here you declare only the authorizer, and the type is derived from its `type`. The `route_authorization`
output shows the effective result for every route: it is the one to look at in a review to know what is
public, without cross-referencing two fields.

## One permission per function, created by the API

The API creates the `aws_lambda_permission`s itself for all the functions it can invoke — the ones
integrated by the routes **plus** the ones used as authorizers — deduplicated. A function behind ten routes
receives a single permission.

The permission is created by the API and not by the function for two reasons: only the API knows its own
execution ARN, and that way permission and integration are the same declaration. The dependency goes from
the API to the function, so there is no cycle.

`source_arn` uses `<execution_arn>/*/*`, which covers both the invocations from the routes and those from
the authorizers — whose source ARN has the form `<api-id>/authorizers/<id>`.

## The WAF is not attached here

**WAFv2 does not support HTTP API Gateways.** It supports REST APIs, and in that case it wants the
*stage*'s ARN, not the API's. The previous wiring associated a WebACL with an HTTP API's
`api_execution_arn`: that code protected nothing.

To protect an HTTP API with the WAF you need CloudFront in front, so the WAF lives on
[`modules/site`](../site).

## Opinionated defaults

| | module default | AWS default | why |
|---|---|---|---|
| throttling | 500 burst / 1000 rps | account quota | an API with no limits in front of Lambda is a cost amplifier: a runaway loop on the client side eats the whole account's concurrency |
| access logs | enabled, JSON | absent | see below |
| `detailed_metrics_enabled` | true | false | without it, there are no per-route metrics |
| `disable_default_endpoint` | false | false | to be enabled with a custom domain, otherwise the API stays reachable from the AWS URL too |

## Access logs

The default format includes `integration.error`, `integration.integrationStatus` and `authorizer.error`.
Without those fields a 500 from the API is indistinguishable from a 500 from the application, and a 401 does
not say whether the authorizer denied or blew up — which is the difference between a configuration problem
and a bug.

## Authorizers

- `type = "lambda"` creates a REQUEST authorizer with `enable_simple_responses` on and a TTL of zero.
- `type = "jwt"` validates the tokens against an OIDC issuer without invoking anything, and produces no
  invocation permissions.

A lambda authorizer with `result_ttl_in_seconds` greater than zero **must** declare at least one
`identity_sources`: without it, the answer is cached for all requests indiscriminately, and whoever gets
through once gets through for everyone until it expires. The module blocks that.

## Notes

- The module does not create ACM certificates: validating them has timings and DNS dependencies that do not
  belong to an API's lifecycle. A custom domain's certificate goes in the **same region** as the API —
  unlike CloudFront, which wants them in us-east-1.
- A Lambda `timeout` beyond 29 seconds behind an HTTP API is pointless: it is the gateway that answers 504.
- The error alarm uses the `5xx` metric, not the REST APIs' `5XXError`. The wrong name raises no error: it
  produces an alarm permanently in `INSUFFICIENT_DATA` that looks like it is working.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_api"></a> [api](#module\_api) | terraform-aws-modules/apigateway-v2/aws | ~> 5.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_metric_alarm.latency](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.server_errors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_lambda_permission.invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | The API's name. If `prefix` is set the final name is `<prefix>-<name>`. | `string` | n/a | yes |
| <a name="input_access_logs"></a> [access\_logs](#input\_access\_logs) | The stage's access logs, in JSON.<br/><br/>The default format includes the integration's error and the authorizer's: without those<br/>two fields, a 500 from the API is indistinguishable from a 500 from the application, and<br/>a 401 does not say whether the authorizer denied or blew up. | <pre>object({<br/>    enabled         = optional(bool, true)<br/>    retention_days  = optional(number, 30)<br/>    kms_key_id      = optional(string)<br/>    destination_arn = optional(string)<br/>  })</pre> | `{}` | no |
| <a name="input_alarms"></a> [alarms](#input\_alarms) | Alarms on errors and latency.<br/><br/>On HTTP APIs the server error metric is `5xx`, not `5XXError` as on the REST APIs: using<br/>the wrong name produces an alarm permanently in INSUFFICIENT\_DATA that looks like it is<br/>working. | <pre>object({<br/>    enabled                = optional(bool, true)<br/>    actions                = optional(list(string), [])<br/>    ok_actions             = optional(list(string), [])<br/>    server_error_threshold = optional(number, 1)<br/>    server_error_period    = optional(number, 300)<br/>    latency_threshold_ms   = optional(number, 3000)<br/>    latency_period         = optional(number, 300)<br/>  })</pre> | `{}` | no |
| <a name="input_authorizers"></a> [authorizers](#input\_authorizers) | The API's authorizers.<br/><br/>`type = "lambda"` uses a function as a REQUEST authorizer; `type = "jwt"` validates the<br/>tokens against an OIDC issuer without invoking anything.<br/><br/>    authorizers = {<br/>      jwt = {<br/>        type = "jwt"<br/>        jwt  = { issuer = "https://acme.eu.auth0.com/", audience = ["https://api.acme.example"] }<br/>      }<br/>      custom = { type = "lambda", function = "authorizer" }<br/>    } | <pre>map(object({<br/>    type                    = optional(string, "lambda")<br/>    function                = optional(string)<br/>    identity_sources        = optional(list(string), ["$request.header.Authorization"])<br/>    result_ttl_in_seconds   = optional(number, 0)<br/>    enable_simple_responses = optional(bool, true)<br/>    jwt = optional(object({<br/>      issuer   = string<br/>      audience = list(string)<br/>    }))<br/>  }))</pre> | `{}` | no |
| <a name="input_cors"></a> [cors](#input\_cors) | CORS configuration.<br/><br/>`allow_credentials = true` together with `allow_origins = ["*"]` is a combination<br/>browsers reject: the module blocks it instead of letting it be discovered from the<br/>frontend. | <pre>object({<br/>    allow_origins     = optional(list(string), [])<br/>    allow_methods     = optional(list(string), [])<br/>    allow_headers     = optional(list(string), ["content-type", "authorization", "x-amz-date", "x-api-key", "x-amz-security-token"])<br/>    expose_headers    = optional(list(string), [])<br/>    allow_credentials = optional(bool, false)<br/>    max_age           = optional(number)<br/>  })</pre> | `null` | no |
| <a name="input_description"></a> [description](#input\_description) | The API's description. | `string` | `null` | no |
| <a name="input_disable_default_endpoint"></a> [disable\_default\_endpoint](#input\_disable\_default\_endpoint) | Disables the `execute-api` endpoint generated by AWS.<br/><br/>To be enabled when there is a custom domain: otherwise the API stays reachable from the<br/>AWS URL too, which bypasses any protections tied to the domain. | `bool` | `false` | no |
| <a name="input_domain"></a> [domain](#input\_domain) | Custom domain. The certificate must be in the **same region** as the API, unlike<br/>CloudFront which wants them in us-east-1.<br/><br/>`zone_name` enables the creation of the Route53 records. | <pre>object({<br/>    name            = string<br/>    certificate_arn = optional(string)<br/>    zone_name       = optional(string)<br/>    create_records  = optional(bool, true)<br/>  })</pre> | `null` | no |
| <a name="input_functions"></a> [functions](#input\_functions) | Integrable functions, by key. Every entry comes from<br/>`modules/function`.`integration_entry`:<br/><br/>    functions = {<br/>      api        = module.api.integration\_entry<br/>      authorizer = module.authorizer.integration\_entry<br/>    }<br/><br/>Both `arn` and `invoke_arn` are needed because they do different things: the API's<br/>integration uses `invoke_arn`, the invocation permission uses `arn`. | <pre>map(object({<br/>    arn        = string<br/>    invoke_arn = string<br/>    name       = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, typically `<project>-<environment>`. | `string` | `null` | no |
| <a name="input_routes"></a> [routes](#input\_routes) | The API's routes. The key is the route key in the form `METHOD /path`, or `$default`.<br/><br/>    routes = {<br/>      "ANY /files"          = { function = "files", authorizer = "jwt" }<br/>      "ANY /files/{proxy+}" = { function = "files", authorizer = "jwt" }<br/>      "GET /health"         = { function = "health" }<br/>    }<br/><br/>`authorization_type` is **not** declared: it is derived from the type of the named<br/>authorizer. In the previous wiring it had to be written by hand next to the<br/>authorizer's key, and the two could diverge — a route with `authorizer_key` and<br/>`authorization_type = "NONE"` is public while looking protected. | <pre>map(object({<br/>    function               = string<br/>    authorizer             = optional(string)<br/>    authorization_scopes   = optional(list(string), [])<br/>    payload_format_version = optional(string, "2.0")<br/>    timeout_milliseconds   = optional(number)<br/><br/>    detailed_metrics_enabled = optional(bool)<br/>    throttling_burst_limit   = optional(number)<br/>    throttling_rate_limit    = optional(number)<br/>  }))</pre> | `{}` | no |
| <a name="input_stage_name"></a> [stage\_name](#input\_stage\_name) | The stage's name. `$default` serves the requests on the endpoint's root, with no prefix in the path. | `string` | `"$default"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |
| <a name="input_throttling"></a> [throttling](#input\_throttling) | Default limits for all the stage's routes.<br/><br/>An API with no limits in front of Lambda is a cost amplifier: a runaway loop on the<br/>client side eats the whole account's concurrency, and the limits belong here, not on the<br/>individual functions. | <pre>object({<br/>    burst_limit = optional(number, 500)<br/>    rate_limit  = optional(number, 1000)<br/>  })</pre> | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_access_log_group_name"></a> [access\_log\_group\_name](#output\_access\_log\_group\_name) | Name of the access logs' log group. Null when they are disabled or sent to an external destination. |
| <a name="output_alarm_arns"></a> [alarm\_arns](#output\_alarm\_arns) | The created alarms' ARNs, by type. An empty map when the alarms are disabled. |
| <a name="output_arn"></a> [arn](#output\_arn) | The API's ARN. |
| <a name="output_domain_name"></a> [domain\_name](#output\_domain\_name) | The custom domain's target domain name, the one to point at in DNS. Null without a custom domain. |
| <a name="output_endpoint"></a> [endpoint](#output\_endpoint) | The `execute-api` endpoint generated by AWS. It stays set even with `disable_default_endpoint`, but in that case it does not answer. |
| <a name="output_execution_arn"></a> [execution\_arn](#output\_execution\_arn) | The execution ARN, the base of the invocation permissions' source ARNs. |
| <a name="output_id"></a> [id](#output\_id) | The API's ID. |
| <a name="output_invoke_url"></a> [invoke\_url](#output\_invoke\_url) | The stage's invocation URL. It is the one to use in the clients. |
| <a name="output_invoked_function_keys"></a> [invoked\_function\_keys](#output\_invoked\_function\_keys) | The keys of the functions this API can invoke, deduplicated.<br/><br/>It is there to verify that a function behind several routes receives a single permission,<br/>and that the authorizer is included: in the previous wiring this deduplication was a<br/>three-level `flatten` inside a single local. |
| <a name="output_route_authorization"></a> [route\_authorization](#output\_route\_authorization) | The effective authorization type for every route, derived from the authorizer.<br/><br/>It is the output to look at in a review: it says which routes are public without having<br/>to work it out by cross-referencing two fields. |
<!-- END_TF_DOCS -->
