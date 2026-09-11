variable "name" {
  description = "The distribution's name. If `prefix` is set the final name is `<prefix>-<name>`."
  type        = string
}

variable "prefix" {
  description = "Naming prefix, typically `<project>-<environment>`."
  type        = string
  default     = null
}

variable "comment" {
  description = "The distribution's comment, the field the console shows. Defaults to the name."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# Origins
# ------------------------------------------------------------------------------

variable "origins" {
  description = <<-EOT
    The origins the distribution fronts. **The module creates none of them**: that is the
    difference with [`modules/site`](../site), which owns its bucket.

    Every entry states exactly one of `bucket` and `http`.

        origins = {
          web      = { bucket = { name = "acme-prod-web" } }
          api      = { http   = { domain_name = "abc123.execute-api.eu-west-1.amazonaws.com" } }
        }

    A `bucket` origin is reached through an Origin Access Control, one per origin, and the
    module returns the read statement to attach to that bucket in `bucket_policy_json`. The
    **name** is declared and not the domain name: the module derives domain and ARN from it,
    which is what keeps the caller free of a cycle between the bucket and this module.
  EOT
  type = map(object({
    bucket = optional(object({
      name        = string
      origin_path = optional(string)

      # Declares that the objects must not be reachable without a signature. It is not
      # itself a control: it makes the plan fail when a behavior serving this origin has
      # no `trusted_key_groups`.
      require_signed_urls = optional(bool, false)
    }))

    http = optional(object({
      domain_name       = string
      origin_path       = optional(string)
      protocol_policy   = optional(string, "https-only")
      ssl_protocols     = optional(list(string), ["TLSv1.2"])
      read_timeout      = optional(number, 30)
      keepalive_timeout = optional(number, 5)

      # Headers injected towards the origin. The way to prove to the origin that the
      # request came through CloudFront, for an endpoint that stays publicly resolvable.
      custom_headers = optional(map(string), {})
    }))
  }))

  validation {
    condition = alltrue([
      for o in values(var.origins) : (o.bucket != null) != (o.http != null)
    ])
    error_message = format(
      "Every origin must state either `bucket` or `http`, not both and not neither. Non-conforming: %s.",
      join(", ", [for k, o in var.origins : k if(o.bucket != null) == (o.http != null)]),
    )
  }

  validation {
    condition = alltrue([
      for o in values(var.origins) : o.http == null || contains(
        ["http-only", "https-only", "match-viewer"], o.http.protocol_policy
      )
    ])
    error_message = "`protocol_policy` must be one of http-only, https-only, match-viewer."
  }
}

# ------------------------------------------------------------------------------
# Behaviors
# ------------------------------------------------------------------------------

variable "default_behavior" {
  description = <<-EOT
    The behavior that serves everything no `path_pattern` matched. Required: a distribution
    without one does not exist.

    `preset` carries the configuration that is easy to get wrong. See `behaviors`.
  EOT
  type = object({
    origin = string
    preset = optional(string, "static")

    cache_policy_id            = optional(string)
    origin_request_policy_id   = optional(string)
    response_headers_policy_id = optional(string)
    allowed_methods            = optional(list(string))
    viewer_protocol_policy     = optional(string, "redirect-to-https")
    compress                   = optional(bool)

    trusted_key_groups    = optional(list(string), [])
    function_associations = optional(map(string), {})
  })

  validation {
    condition     = contains(["static", "api", "private-files"], var.default_behavior.preset)
    error_message = "`preset` must be one of static, api, private-files."
  }
}

variable "behaviors" {
  description = <<-EOT
    Behaviors by path, **in order**: CloudFront evaluates them in the order given and stops
    at the first `path_pattern` that matches. It is a list and not a map for that reason —
    Terraform orders a map by key, and here the order carries meaning.

        behaviors = [
          { path_pattern = "/api/*",     origin = "api",     preset = "api" },
          { path_pattern = "/exports/*", origin = "exports", preset = "private-files",
            trusted_key_groups = ["downloads"] },
        ]

    `preset` resolves the cache policy, the origin request policy, the allowed methods and
    compression together:

    | preset | cache | origin request | methods |
    |---|---|---|---|
    | `static` | CachingOptimized | — | GET, HEAD, OPTIONS |
    | `api` | CachingDisabled | AllViewerExceptHostHeader | all |
    | `private-files` | CachingOptimized | — | GET, HEAD |

    It exists because of one failure in particular: an API served with the static preset
    loses the `Authorization` header — the cache policy does not forward it — and answers
    401 on everything, with nothing anywhere saying why. The explicit fields override the
    preset one at a time, and stay readable in the plan.

    `private-files` differs from `static` in a single respect: it is the preset to use on an
    origin declared `require_signed_urls`, and like any other behavior on such an origin it
    must carry `trusted_key_groups`.
  EOT
  type = list(object({
    path_pattern = string
    origin       = string
    preset       = optional(string, "static")

    cache_policy_id            = optional(string)
    origin_request_policy_id   = optional(string)
    response_headers_policy_id = optional(string)
    allowed_methods            = optional(list(string))
    viewer_protocol_policy     = optional(string, "redirect-to-https")
    compress                   = optional(bool)

    # Keys of `key_groups`. Empty means the path is served to anyone who reaches it.
    trusted_key_groups = optional(list(string), [])

    # ARNs of already existing CloudFront Functions, by event type — `viewer-request` or
    # `viewer-response`. The module associates them and nothing else: rewriting a URI is
    # JavaScript, and a Terraform module is the wrong place to keep JavaScript.
    function_associations = optional(map(string), {})
  }))
  default = []

  validation {
    condition     = length(var.behaviors) == length(distinct([for b in var.behaviors : b.path_pattern]))
    error_message = "Two behaviors share a `path_pattern`: the second is dead code, because CloudFront stops at the first match."
  }

  validation {
    condition = alltrue(flatten([
      for b in var.behaviors : [
        for e in keys(b.function_associations) : contains(["viewer-request", "viewer-response"], e)
      ]
    ]))
    error_message = "`function_associations` accepts only the keys `viewer-request` and `viewer-response`."
  }

  validation {
    condition     = alltrue([for b in var.behaviors : contains(["static", "api", "private-files"], b.preset)])
    error_message = "`preset` must be one of static, api, private-files."
  }
}

# ------------------------------------------------------------------------------
# Signed URLs
# ------------------------------------------------------------------------------

variable "key_groups" {
  description = <<-EOT
    Key groups for signed URLs and signed cookies. A behavior that names one serves nothing
    without a valid signature.

    The module receives **public** keys. The private one never appears here: it lives in a
    secret and belongs to whoever signs the URLs.

        key_groups = {
          downloads = {
            public_keys = { "2026-09" = { encoded_key = file("public.pem") } }
          }
        }

    More than one key in a group is only needed during a rotation: add the new one, start
    signing with it, wait out the longest expiry still in circulation, remove the old one.
    AWS allows up to five.
  EOT
  type = map(object({
    comment = optional(string)
    public_keys = map(object({
      encoded_key = string
      comment     = optional(string)
    }))
  }))
  default = {}

  validation {
    condition     = alltrue([for g in values(var.key_groups) : length(g.public_keys) > 0])
    error_message = "A key group with no public key accepts no signature: every request to a behavior that names it is refused."
  }

  validation {
    condition     = alltrue([for g in values(var.key_groups) : length(g.public_keys) <= 5])
    error_message = "AWS allows at most 5 public keys per key group."
  }
}

# ------------------------------------------------------------------------------
# Distribution
# ------------------------------------------------------------------------------

variable "aliases" {
  description = "Alternative domain names for the distribution. They require `certificate_arn`."
  type        = list(string)
  default     = []
}

variable "certificate_arn" {
  description = <<-EOT
    ACM certificate for the aliases. **It must be in us-east-1**: CloudFront does not accept
    certificates from other regions, and the error you get otherwise does not say so.

    The module does not create certificates: validating them has timings and DNS dependencies
    that do not belong to a distribution's lifecycle.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.certificate_arn == null || can(regex("^arn:aws[a-z-]*:acm:us-east-1:", coalesce(var.certificate_arn, "x")))
    error_message = "The certificate must be in us-east-1: CloudFront does not accept certificates from other regions."
  }
}

variable "web_acl_arn" {
  description = "WAFv2 WebACL to associate, of `CLOUDFRONT` scope — its ARN contains `global/webacl`."
  type        = string
  default     = null

  validation {
    condition     = var.web_acl_arn == null || can(regex("global/webacl/", coalesce(var.web_acl_arn, "x")))
    error_message = "The WebACL must be of CLOUDFRONT scope: its ARN contains 'global/webacl/'. A REGIONAL ACL cannot be associated with CloudFront."
  }
}

variable "zone_id" {
  description = "The Route53 zone in which to create the alias records for the `aliases`. Null creates no records."
  type        = string
  default     = null
}

variable "default_root_object" {
  description = <<-EOT
    The object served on the root. Null by default, unlike `modules/site`: a distribution
    that aggregates services has no index of its own, and pointing the root at one of the
    origins is a decision, not a default.
  EOT
  type        = string
  default     = null
}

variable "custom_error_responses" {
  description = "Custom error responses for the whole distribution."
  type = list(object({
    error_code            = number
    response_code         = optional(number)
    response_page_path    = optional(string)
    error_caching_min_ttl = optional(number)
  }))
  default = []
}

variable "price_class" {
  description = "Price class. `PriceClass_100` covers Europe and North America and costs less."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "logging" {
  description = "The distribution's access logs towards a bucket. The bucket must have ACLs enabled, which is why it is never one of the origins."
  type = object({
    bucket          = string
    prefix          = optional(string)
    include_cookies = optional(bool, false)
  })
  default = null
}

variable "wait_for_deployment" {
  description = "Waits for the distribution to be fully propagated. `false` makes applies much faster during development."
  type        = bool
  default     = false
}
