# site

A static site: a **private** S3 bucket, CloudFront with Origin Access Control, security headers, Route53
and a hook for the WAF.

The distribution is written with native resources and not through CloudFront's upstream module. It is a
deliberate deviation from the rule of wrapping: that module addresses the OAC **by key**, and that very
indirection produced the defect this module exists to correct.

## Usage

```hcl
module "web" {
  source = "…//modules/site"

  prefix = "acme-prod"
  name   = "web"

  aliases         = ["app.acme.example"]
  certificate_arn = var.us_east_1_certificate_arn   # must be in us-east-1
  zone_id         = var.zone_id

  spa = true
}
```

Deploying the content stays with CI:

```bash
aws s3 sync ./dist "s3://$(terraform output -raw bucket_name)" --delete
aws cloudfront create-invalidation --distribution-id "$(terraform output -raw distribution_id)" --paths '/*'
```

## The defect this module corrects

In the previous wiring the distribution's origin pointed at the OAC key `"s3_${k}"`, while the map of OACs
was indexed `${k}`. The lookup found nothing, **the OAC was a no-op**, and the distribution only worked
because the bucket was publicly readable.

The consequences were not theoretical: with a public bucket CloudFront is **bypassable**. Anyone who knows
the bucket's name reads the objects from the S3 endpoint, skipping WAF, logging, cache and security
headers. And nothing reports it: the CDN answers correctly, so it looks well configured.

Here the OAC is a direct reference to the resource — not a lookup by key — and the bucket stays private,
with a policy that authorizes only `cloudfront.amazonaws.com` scoped to **this** distribution through
`AWS:SourceArn`.

The `origin_access_control_id` output exists to make exactly this inspectable.

## One bucket, one policy

The OAC statement is not a resource of this module: it is passed to `modules/bucket` through `policy_json`,
which merges it with the TLS statements into the single policy S3 allows per bucket.

It used to be an `aws_s3_bucket_policy` declared here, next to the one the bucket module creates. Two
resources on the same document, each replacing the other: what was deployed was whichever applied last —
either without the OAC access, and the distribution answers 403 on everything, or without the TLS
enforcement, and the audit finding comes back. Neither Terraform nor AWS reports the conflict.

Upgrading from a version that had the duplicate needs nothing on the caller's side. The module ships a
`removed` block with `destroy = false`: the old resource is forgotten instead of destroyed, because
destroying it would call `DeleteBucketPolicy` and wipe the document the surviving resource manages, and
Terraform does not order a destroy against an update of another resource on the same API object. Expect one
update on the bucket's policy, adding whichever set of statements the duplicate had been overwriting.

The `bucket_policy_json` output exposes the document this module contributes.

## The SPA preset

`spa = true` rewrites 403 and 404 to 200 on `/index.html`, so that client-side routing works on deep URLs.
The 403 matters just as much as the 404: with a private bucket and OAC, a missing object produces a 403,
not a 404.

**Leave it disabled on asset buckets.** With the preset on, a missing asset returns the index with a 200
code: a file that does not exist becomes indistinguishable from one that does, and the clients never find
out.

## Opinionated defaults

| | module default | why |
|---|---|---|
| bucket | **private, not configurable** | see above |
| `viewer_protocol_policy` | `redirect-to-https` | |
| response headers policy | managed `SecurityHeadersPolicy` | HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` and a basic CSP, for free |
| cache policy | managed `CachingOptimized` | |
| `minimum_protocol_version` | `TLSv1.2_2021` | only with an ACM certificate; CloudFront's default certificate does not allow it |
| `price_class` | `PriceClass_100` | Europe and North America; the rest costs more than most cases need |
| `compress` | true | |
| `wait_for_deployment` | **false** | waiting for propagation adds minutes to every apply without changing the result |

## Guardrails

Two configuration mistakes whose diagnosis from AWS is opaque are blocked in the plan:

- **Certificate outside us-east-1.** CloudFront does not accept certificates from other regions. It is one
  of AWS's most annoying asymmetries, because an API Gateway certificate's region is instead the API's own.
- **WebACL of REGIONAL scope.** Only `CLOUDFRONT` ACLs can be associated with a distribution: their ARN
  contains `global/webacl/`.

Plus two inconsistencies: aliases without a certificate (the requests on the aliases would fail in TLS) and
`zone_id` without aliases (there is no record to create).

## Alarms: there are none, and that is deliberate

CloudFront's metrics exist **only in us-east-1**. An alarm on them has to be created there, and creating it
from this module would require imposing an aliased `us-east-1` provider on every caller, including those
who do not use the alarms.

Alarms on CloudFront belong to a us-east-1 stack — the `edge` layer of a layered configuration. The module
exposes `distribution_id` and `distribution_arn` to build them there.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_bucket"></a> [bucket](#module\_bucket) | ../bucket | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudfront_distribution.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_cloudfront_origin_access_control.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_origin_access_control) | resource |
| [aws_route53_record.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | The site's name, used for the bucket and the distribution. If `prefix` is set the final name is `<prefix>-<name>`. | `string` | n/a | yes |
| <a name="input_aliases"></a> [aliases](#input\_aliases) | Alternative domain names for the distribution. They require `certificate_arn`. | `list(string)` | `[]` | no |
| <a name="input_allowed_methods"></a> [allowed\_methods](#input\_allowed\_methods) | HTTP methods accepted by the default behavior. A static site needs no more than GET, HEAD and OPTIONS. | `list(string)` | <pre>[<br/>  "GET",<br/>  "HEAD",<br/>  "OPTIONS"<br/>]</pre> | no |
| <a name="input_bucket_force_destroy"></a> [bucket\_force\_destroy](#input\_bucket\_force\_destroy) | Lets Terraform delete the bucket even if it contains objects. Necessary in throwaway environments. | `bool` | `false` | no |
| <a name="input_bucket_versioning_enabled"></a> [bucket\_versioning\_enabled](#input\_bucket\_versioning\_enabled) | Versioning of the content bucket. | `bool` | `true` | no |
| <a name="input_cache_policy_id"></a> [cache\_policy\_id](#input\_cache\_policy\_id) | Cache policy of the default behavior. The default is AWS's managed `CachingOptimized`. | `string` | `"658327ea-f89d-4fab-a63d-7e88639e58f6"` | no |
| <a name="input_certificate_arn"></a> [certificate\_arn](#input\_certificate\_arn) | ACM certificate for the aliases. **It must be in us-east-1**: CloudFront does not accept<br/>certificates from other regions, and the error you get otherwise does not say so.<br/><br/>The module does not create certificates: validating them has timings and DNS dependencies<br/>that do not belong to a distribution's lifecycle. | `string` | `null` | no |
| <a name="input_comment"></a> [comment](#input\_comment) | The CloudFront distribution's comment, visible in the console. | `string` | `null` | no |
| <a name="input_custom_error_responses"></a> [custom\_error\_responses](#input\_custom\_error\_responses) | Custom error responses, on top of the ones generated by the `spa` preset. | <pre>list(object({<br/>    error_code            = number<br/>    response_code         = optional(number)<br/>    response_page_path    = optional(string)<br/>    error_caching_min_ttl = optional(number)<br/>  }))</pre> | `[]` | no |
| <a name="input_default_root_object"></a> [default\_root\_object](#input\_default\_root\_object) | The object served on the root. | `string` | `"index.html"` | no |
| <a name="input_logging"></a> [logging](#input\_logging) | The distribution's access logs towards a bucket. The bucket must have ACLs enabled, which is why it is not the site's own. | <pre>object({<br/>    bucket          = string<br/>    prefix          = optional(string)<br/>    include_cookies = optional(bool, false)<br/>  })</pre> | `null` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, typically `<project>-<environment>`. | `string` | `null` | no |
| <a name="input_price_class"></a> [price\_class](#input\_price\_class) | Price class. `PriceClass_100` covers Europe and North America and costs less. | `string` | `"PriceClass_100"` | no |
| <a name="input_response_headers_policy_id"></a> [response\_headers\_policy\_id](#input\_response\_headers\_policy\_id) | Response headers policy. The default is AWS's managed `SecurityHeadersPolicy`, which adds<br/>HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` and a basic<br/>`Content-Security-Policy`.<br/><br/>Passing `null` disables it: those headers are free and have no downsides on a static site,<br/>so giving them up is worth an explicit choice. | `string` | `"67f7725c-6f97-4210-82d7-5512b31e9d03"` | no |
| <a name="input_spa"></a> [spa](#input\_spa) | Preset for a single page application: the origin's 403 and 404 responses are rewritten to<br/>200 on `/index.html`, so that client-side routing works on deep URLs.<br/><br/>**Leave it disabled for asset buckets.** With the preset on, a missing object returns the<br/>index with a 200 code: an asset that does not exist becomes indistinguishable from one<br/>that does, and the clients never find out. | `bool` | `false` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |
| <a name="input_wait_for_deployment"></a> [wait\_for\_deployment](#input\_wait\_for\_deployment) | Waits for the distribution to be fully propagated. `false` makes applies much faster during development. | `bool` | `false` | no |
| <a name="input_web_acl_arn"></a> [web\_acl\_arn](#input\_web\_acl\_arn) | WAFv2 WebACL to associate with the distribution. It must be of `CLOUDFRONT` scope, whose<br/>ARN contains `global/webacl`.<br/><br/>It is here and not on `modules/http-api` for a technical reason: **WAFv2 cannot be<br/>associated with an HTTP API Gateway**. It only supports REST APIs, and requires the<br/>stage's ARN. To protect an HTTP API with the WAF you need CloudFront in front. | `string` | `null` | no |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | The Route53 zone in which to create the alias records for the `aliases`. Null creates no records. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_bucket_arn"></a> [bucket\_arn](#output\_bucket\_arn) | ARN of the content bucket. |
| <a name="output_bucket_name"></a> [bucket\_name](#output\_bucket\_name) | Name of the content bucket. It is the target of the `aws s3 sync` calls from CI. |
| <a name="output_bucket_policy_json"></a> [bucket\_policy\_json](#output\_bucket\_policy\_json) | The document this module contributes to the content bucket's policy: read access for<br/>CloudFront through the OAC, scoped to this distribution with `AWS:SourceArn`.<br/><br/>`modules/bucket` merges it with the TLS statements into the single policy S3 allows per<br/>bucket. It is exposed because the bucket's effective policy is not this document alone,<br/>and because a second `aws_s3_bucket_policy` on that bucket would replace it in silence. |
| <a name="output_bucket_registry_entry"></a> [bucket\_registry\_entry](#output\_bucket\_registry\_entry) | The bucket's registry entry, to give a function permission to write to it — for example<br/>to publish generated content.<br/><br/>    resources = { buckets = { site = module.site.bucket\_registry\_entry } } |
| <a name="output_distribution_arn"></a> [distribution\_arn](#output\_distribution\_arn) | The distribution's ARN. |
| <a name="output_distribution_id"></a> [distribution\_id](#output\_distribution\_id) | The distribution's ID. Needed for invalidations from CI. |
| <a name="output_domain_name"></a> [domain\_name](#output\_domain\_name) | The domain name assigned by CloudFront, the one to use if there are no aliases. |
| <a name="output_hosted_zone_id"></a> [hosted\_zone\_id](#output\_hosted\_zone\_id) | CloudFront's hosted zone ID, to create alias records in a zone managed elsewhere. |
| <a name="output_origin_access_control_id"></a> [origin\_access\_control\_id](#output\_origin\_access\_control\_id) | ID of the Origin Access Control actually associated with the origin.<br/><br/>It is exposed because its absence is the defect this module corrects: an OAC that is<br/>created but not linked leaves the distribution working only if the bucket is public, and<br/>reports it in no way at all. |
| <a name="output_spa_error_response_codes"></a> [spa\_error\_response\_codes](#output\_spa\_error\_response\_codes) | The error codes rewritten by the SPA preset. An empty list when the preset is disabled. |
<!-- END_TF_DOCS -->
