variable "name" {
  description = "The API's name. If `prefix` is set the final name is `<prefix>-<name>`."
  type        = string
}

variable "prefix" {
  description = "Naming prefix, typically `<project>-<environment>`."
  type        = string
  default     = null
}

variable "description" {
  description = "The API's description."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}

variable "functions" {
  description = <<-EOT
    Integrable functions, by key. Every entry comes from
    `modules/function`.`integration_entry`:

        functions = {
          api        = module.api.integration_entry
          authorizer = module.authorizer.integration_entry
        }

    Both `arn` and `invoke_arn` are needed because they do different things: the API's
    integration uses `invoke_arn`, the invocation permission uses `arn`.
  EOT
  type = map(object({
    arn        = string
    invoke_arn = string
    name       = optional(string)
  }))
  default = {}
}

variable "routes" {
  description = <<-EOT
    The API's routes. The key is the route key in the form `METHOD /path`, or `$default`.

        routes = {
          "ANY /files"          = { function = "files", authorizer = "jwt" }
          "ANY /files/{proxy+}" = { function = "files", authorizer = "jwt" }
          "GET /health"         = { function = "health" }
        }

    `authorization_type` is **not** declared: it is derived from the type of the named
    authorizer. In the previous wiring it had to be written by hand next to the
    authorizer's key, and the two could diverge — a route with `authorizer_key` and
    `authorization_type = "NONE"` is public while looking protected.
  EOT
  type = map(object({
    function               = string
    authorizer             = optional(string)
    authorization_scopes   = optional(list(string), [])
    payload_format_version = optional(string, "2.0")
    timeout_milliseconds   = optional(number)

    detailed_metrics_enabled = optional(bool)
    throttling_burst_limit   = optional(number)
    throttling_rate_limit    = optional(number)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k in keys(var.routes) :
      k == "$default" || can(regex("^(ANY|GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /", k))
    ])
    error_message = format(
      "The routes keys must be '$default' or '<METHOD> /<path>'. Non-conforming: %s.",
      join(", ", [
        for k in keys(var.routes) : format("'%s'", k)
        if !(k == "$default" || can(regex("^(ANY|GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /", k)))
      ]),
    )
  }

  validation {
    condition = alltrue([for r in values(var.routes) : contains(keys(var.functions), r.function)])
    error_message = format(
      "Routes referencing functions not present in `functions`: %s. Available functions: %s.",
      join(", ", [for k, r in var.routes : format("'%s' → '%s'", k, r.function) if !contains(keys(var.functions), r.function)]),
      join(", ", keys(var.functions)),
    )
  }
}

variable "authorizers" {
  description = <<-EOT
    The API's authorizers.

    `type = "lambda"` uses a function as a REQUEST authorizer; `type = "jwt"` validates the
    tokens against an OIDC issuer without invoking anything.

        authorizers = {
          jwt = {
            type = "jwt"
            jwt  = { issuer = "https://acme.eu.auth0.com/", audience = ["https://api.acme.example"] }
          }
          custom = { type = "lambda", function = "authorizer" }
        }
  EOT
  type = map(object({
    type                    = optional(string, "lambda")
    function                = optional(string)
    identity_sources        = optional(list(string), ["$request.header.Authorization"])
    result_ttl_in_seconds   = optional(number, 0)
    enable_simple_responses = optional(bool, true)
    jwt = optional(object({
      issuer   = string
      audience = list(string)
    }))
  }))
  default = {}

  validation {
    condition     = alltrue([for a in values(var.authorizers) : contains(["lambda", "jwt"], a.type)])
    error_message = "authorizers.type must be 'lambda' or 'jwt'."
  }

  validation {
    condition = alltrue([
      for a in values(var.authorizers) : a.type != "lambda" || a.function != null
    ])
    error_message = "An authorizer of type 'lambda' requires `function`."
  }

  validation {
    condition = alltrue([
      for a in values(var.authorizers) : a.type != "jwt" || a.jwt != null
    ])
    error_message = "An authorizer of type 'jwt' requires the `jwt` block with issuer and audience."
  }

  # `a.function == null ? "" : a.function` and not `coalesce(a.function, "")`: coalesce
  # rejects the empty string too, so with function null it would raise a function error
  # instead of failing this validation. All validations are evaluated, even when another
  # one has already caught the problem.
  validation {
    condition = alltrue([
      for a in values(var.authorizers) :
      a.type != "lambda" || contains(keys(var.functions), a.function == null ? "" : a.function)
    ])
    error_message = format(
      "Authorizers referencing functions not present in `functions`. Available functions: %s.",
      join(", ", keys(var.functions)),
    )
  }

  # A non-zero TTL with an empty `identity_sources` caches the authorizer's answer for all
  # requests indiscriminately: whoever gets through once gets through for everyone until it
  # expires.
  validation {
    condition = alltrue([
      for a in values(var.authorizers) :
      a.type != "lambda" || a.result_ttl_in_seconds == 0 || length(a.identity_sources) > 0
    ])
    error_message = "A lambda authorizer with `result_ttl_in_seconds` greater than zero must declare at least one `identity_sources`: without it, the answer is cached for all requests indiscriminately."
  }
}

variable "cors" {
  description = <<-EOT
    CORS configuration.

    `allow_credentials = true` together with `allow_origins = ["*"]` is a combination
    browsers reject: the module blocks it instead of letting it be discovered from the
    frontend.
  EOT
  type = object({
    allow_origins     = optional(list(string), [])
    allow_methods     = optional(list(string), [])
    allow_headers     = optional(list(string), ["content-type", "authorization", "x-amz-date", "x-api-key", "x-amz-security-token"])
    expose_headers    = optional(list(string), [])
    allow_credentials = optional(bool, false)
    max_age           = optional(number)
  })
  default = null

  validation {
    condition     = var.cors == null || !(var.cors.allow_credentials && contains(var.cors.allow_origins, "*"))
    error_message = "allow_credentials = true is not compatible with allow_origins = [\"*\"]: browsers reject the response. List the origins explicitly."
  }
}

variable "domain" {
  description = <<-EOT
    Custom domain. The certificate must be in the **same region** as the API, unlike
    CloudFront which wants them in us-east-1.

    `zone_name` enables the creation of the Route53 records.
  EOT
  type = object({
    name            = string
    certificate_arn = optional(string)
    zone_name       = optional(string)
    create_records  = optional(bool, true)
  })
  default = null

  validation {
    condition     = var.domain == null || var.domain.certificate_arn != null
    error_message = "With a custom domain `certificate_arn` is required: the module does not create certificates, because validating them is not part of an API's lifecycle."
  }

  validation {
    condition     = var.domain == null || !var.domain.create_records || var.domain.zone_name != null
    error_message = "Creating the Route53 records requires `zone_name`. If the zone is managed elsewhere, set `create_records = false`."
  }
}

variable "stage_name" {
  description = "The stage's name. `$default` serves the requests on the endpoint's root, with no prefix in the path."
  type        = string
  default     = "$default"
}

variable "throttling" {
  description = <<-EOT
    Default limits for all the stage's routes.

    An API with no limits in front of Lambda is a cost amplifier: a runaway loop on the
    client side eats the whole account's concurrency, and the limits belong here, not on the
    individual functions.
  EOT
  type = object({
    burst_limit = optional(number, 500)
    rate_limit  = optional(number, 1000)
  })
  default = {}
}

variable "access_logs" {
  description = <<-EOT
    The stage's access logs, in JSON.

    The default format includes the integration's error and the authorizer's: without those
    two fields, a 500 from the API is indistinguishable from a 500 from the application, and
    a 401 does not say whether the authorizer denied or blew up.
  EOT
  type = object({
    enabled         = optional(bool, true)
    retention_days  = optional(number, 30)
    kms_key_id      = optional(string)
    destination_arn = optional(string)
  })
  default = {}
}

variable "disable_default_endpoint" {
  description = <<-EOT
    Disables the `execute-api` endpoint generated by AWS.

    To be enabled when there is a custom domain: otherwise the API stays reachable from the
    AWS URL too, which bypasses any protections tied to the domain.
  EOT
  type        = bool
  default     = false
}

variable "alarms" {
  description = <<-EOT
    Alarms on errors and latency.

    On HTTP APIs the server error metric is `5xx`, not `5XXError` as on the REST APIs: using
    the wrong name produces an alarm permanently in INSUFFICIENT_DATA that looks like it is
    working.
  EOT
  type = object({
    enabled                = optional(bool, true)
    actions                = optional(list(string), [])
    ok_actions             = optional(list(string), [])
    server_error_threshold = optional(number, 1)
    server_error_period    = optional(number, 300)
    latency_threshold_ms   = optional(number, 3000)
    latency_period         = optional(number, 300)
  })
  default = {}
}
