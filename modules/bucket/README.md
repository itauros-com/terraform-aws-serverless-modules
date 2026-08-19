# bucket

A private S3 bucket with versioning, encryption, lifecycle, CORS and notifications. It wraps
[`terraform-aws-modules/s3-bucket/aws`](https://github.com/terraform-aws-modules/terraform-aws-s3-bucket)
`~> 5.0`.

## Usage

```hcl
module "documents" {
  source = "…//modules/bucket"

  prefix = "acme-prod"
  name   = "documents"

  notifications = {
    queues = {
      ingest = {
        queue_arn     = module.ingest.arn
        events        = ["s3:ObjectCreated:*"]
        filter_prefix = "incoming/"
      }
    }
  }

  lifecycle_rules = [
    {
      id                                     = "cleanup"
      noncurrent_version_expiration          = { noncurrent_days = 30 }
      abort_incomplete_multipart_upload_days = 7
    }
  ]
}
```

## The bucket is always private

The public access block is on and **cannot be disabled from the module**. There is no input to make it
public.

To serve static web content you use `modules/site`, which puts CloudFront in front of a private bucket
with Origin Access Control. A public bucket behind CloudFront makes CloudFront **bypassable**: anyone who
knows the bucket's name reads the objects from the S3 endpoint, skipping WAF, logging and the cache. It is
exactly the situation found in the wiring this library grew out of, where the OAC was configured with a
key that matched nothing and the distribution only worked because the bucket was readable by everyone.

`object_ownership` is `BucketOwnerEnforced` by default: ACLs are disabled entirely, so it is not possible
to expose an object by mistake through an ACL.

## The notifications all live here

S3 allows **a single notification configuration per bucket**, and every write replaces the previous one
entirely. Two Terraform resources configuring notifications on the same bucket overwrite each other,
silently and in non-deterministic order. That is why `notifications` is a single input collecting queues,
topics and functions, and produces a single resource.

For functions the module also creates the `aws_lambda_permission`: permission and notification are the
same declaration, so they cannot diverge. The dependency goes from the bucket to the function, so there is
no cycle.

Queues and topics must in turn authorize S3. There the dependency would go in the opposite direction and
would create a cycle, so the bucket's ARN is passed as a **string** — the `static_arn` output computes it
from the name alone:

```hcl
module "ingest" {
  source          = "…//modules/queue"
  allow_send_from = [{ service = "s3", source_arn = "arn:aws:s3:::acme-prod-documents" }]
}
```

## The policy lives here too, for the same reason

S3 also stores **a single policy document per bucket**, and every `PutBucketPolicy` replaces it whole. The
module always attaches two statements of its own — deny insecure transport, require the latest TLS — so the
policy resource always exists. A consumer that declares a second `aws_s3_bucket_policy` on the same bucket
does not add statements to it: it replaces them, in a non-deterministic order and with no error from either
side. What is deployed is whichever of the two applied last.

So the caller's statements go in through `policy_json`, and the module merges them with its own:

```hcl
module "web" {
  source      = "…//modules/bucket"
  policy_json = data.aws_iam_policy_document.oac.json
}
```

`attach_policy` is derived from `policy_json` and only needs declaring when the document is not known at
plan time because it references the ARN of a resource that does not exist yet — an unknown value compared
with `null` is unknown too. `modules/site` is in exactly that position: its statement is scoped to the ARN
of the distribution it is creating.

The `policy_json_attached` output reports whether the caller's document is part of the policy.

## Opinionated defaults

| | module default | AWS default | why |
|---|---|---|---|
| public access block | **on, cannot be disabled** | on | see above |
| versioning | **enabled** | disabled | it is the only way to recover an overwritten or deleted object |
| encryption | `AES256` | `AES256` | with `kms_key_arn` it switches to SSE-KMS **and enables the bucket key**, which greatly reduces billable KMS requests |
| `object_ownership` | `BucketOwnerEnforced` | `BucketOwnerEnforced` | ACLs disabled |
| deny non-TLS | **on** | absent | two statements with no downsides that an audit always asks for |
| `force_destroy` | `false` | `false` | |

Versioning costs in storage: you keep it in check with a lifecycle rule that expires the non-current
versions, as in the example above.

## No alarms

S3's request metrics (4xx, 5xx, latency) require enabling *request metrics*, which are billed per request.
Enabling them by default would introduce a cost nobody asked for, so the module creates no alarms. If you
need them, enable request metrics and create the alarms in the caller.

## Notes

- `abort_incomplete_multipart_upload_days` deserves a rule on every bucket that receives large uploads:
  the fragments of aborted uploads do not appear among the objects but are billed indefinitely.
- A `*` in a CORS rule's `allowed_origins` together with other origins is rejected: the list would give
  the impression of restricting something that is in fact open to everyone.
- The bucket's name is globally unique across all of AWS: the `prefix` with project and environment serves
  that purpose too.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_s3"></a> [s3](#module\_s3) | terraform-aws-modules/s3-bucket/aws | ~> 5.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_lambda_permission.notification](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_s3_bucket_notification.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | The bucket's name. If `prefix` is set the final name is `<prefix>-<name>`. It must be globally unique on AWS. | `string` | n/a | yes |
| <a name="input_attach_policy"></a> [attach\_policy](#input\_attach\_policy) | Whether `policy_json` takes part in the bucket's policy. Derived from `policy_json`<br/>when null, which is what almost every caller wants.<br/><br/>Declare it only when the document is not known at plan time because it references the<br/>ARN of a resource that does not exist yet: an unknown value compared with `null` is<br/>itself unknown, and the decision would be made on a value nobody can read at that<br/>point. `modules/site` is in exactly that position — its statement is scoped to the<br/>ARN of the distribution it is creating. | `bool` | `null` | no |
| <a name="input_cors_rules"></a> [cors\_rules](#input\_cors\_rules) | The bucket's CORS rules. | <pre>list(object({<br/>    id              = optional(string)<br/>    allowed_methods = list(string)<br/>    allowed_origins = list(string)<br/>    allowed_headers = optional(list(string))<br/>    expose_headers  = optional(list(string))<br/>    max_age_seconds = optional(number)<br/>  }))</pre> | `[]` | no |
| <a name="input_encryption"></a> [encryption](#input\_encryption) | Encryption at rest. `AES256` (SSE-S3) by default, at no additional cost.<br/><br/>With `kms_key_arn` it switches to SSE-KMS and the **bucket key** is enabled, which<br/>greatly reduces KMS calls and therefore cost: without it, every GET and every PUT is<br/>a billable KMS request. | <pre>object({<br/>    kms_key_arn = optional(string)<br/>  })</pre> | `{}` | no |
| <a name="input_force_destroy"></a> [force\_destroy](#input\_force\_destroy) | Lets Terraform delete a non-empty bucket. Keep it false on anything holding real data. | `bool` | `false` | no |
| <a name="input_lifecycle_rules"></a> [lifecycle\_rules](#input\_lifecycle\_rules) | Lifecycle rules.<br/><br/>`abort_incomplete_multipart_upload_days` deserves a rule on every bucket that<br/>receives large uploads: the fragments of aborted uploads are not visible among the<br/>objects but are billed indefinitely. | <pre>list(object({<br/>    id      = string<br/>    enabled = optional(bool, true)<br/>    filter = optional(object({<br/>      prefix                   = optional(string)<br/>      tags                     = optional(map(string))<br/>      object_size_greater_than = optional(number)<br/>      object_size_less_than    = optional(number)<br/>    }))<br/>    expiration = optional(object({<br/>      days                         = optional(number)<br/>      date                         = optional(string)<br/>      expired_object_delete_marker = optional(bool)<br/>    }))<br/>    noncurrent_version_expiration = optional(object({<br/>      noncurrent_days           = number<br/>      newer_noncurrent_versions = optional(number)<br/>    }))<br/>    transition = optional(list(object({<br/>      days          = number<br/>      storage_class = string<br/>    })), [])<br/>    noncurrent_version_transition = optional(list(object({<br/>      noncurrent_days = number<br/>      storage_class   = string<br/>    })), [])<br/>    abort_incomplete_multipart_upload_days = optional(number)<br/>  }))</pre> | `[]` | no |
| <a name="input_logging"></a> [logging](#input\_logging) | Server access logging towards another bucket. | <pre>object({<br/>    target_bucket = string<br/>    target_prefix = optional(string)<br/>  })</pre> | `null` | no |
| <a name="input_notifications"></a> [notifications](#input\_notifications) | Notifications of the bucket's events towards queues, topics and functions.<br/><br/>They must **all be declared here**: S3 allows a single notification configuration<br/>per bucket, and every write replaces the previous one entirely. Two Terraform<br/>resources configuring notifications on the same bucket overwrite each other,<br/>silently and in non-deterministic order.<br/><br/>For functions the module also creates the necessary `aws_lambda_permission`: the<br/>permission and the notification are the same declaration, so they cannot diverge.<br/><br/>The queues and topics must in turn authorize S3 to write. On the queue side you do<br/>that with `allow_send_from`, on the topic side with `allow_publish_from`, passing the<br/>bucket's ARN as a literal string so as not to create a cycle between the modules.<br/><br/>    notifications = {<br/>      queues = {<br/>        ingest = { queue\_arn = module.ingest.arn, events = ["s3:ObjectCreated:*"], filter\_prefix = "incoming/" }<br/>      }<br/>    } | <pre>object({<br/>    queues = optional(map(object({<br/>      queue_arn     = string<br/>      events        = list(string)<br/>      filter_prefix = optional(string)<br/>      filter_suffix = optional(string)<br/>    })), {})<br/>    topics = optional(map(object({<br/>      topic_arn     = string<br/>      events        = list(string)<br/>      filter_prefix = optional(string)<br/>      filter_suffix = optional(string)<br/>    })), {})<br/>    functions = optional(map(object({<br/>      function_arn  = string<br/>      events        = list(string)<br/>      filter_prefix = optional(string)<br/>      filter_suffix = optional(string)<br/>    })), {})<br/>  })</pre> | `{}` | no |
| <a name="input_object_ownership"></a> [object\_ownership](#input\_object\_ownership) | Object ownership management. `BucketOwnerEnforced` disables ACLs entirely, which is<br/>the default AWS has recommended since 2023 and makes it impossible to expose an<br/>object by mistake through an ACL. | `string` | `"BucketOwnerEnforced"` | no |
| <a name="input_policy_json"></a> [policy\_json](#input\_policy\_json) | Statements to add to the bucket's policy, as a JSON document.<br/><br/>They are **merged** with the ones the module always attaches — deny insecure<br/>transport, require the latest TLS — into the single policy the bucket has. S3 stores<br/>one document per bucket and every write replaces it whole, so a consumer that needs<br/>its own statements passes them here instead of declaring a second<br/>`aws_s3_bucket_policy` on the same bucket, which would overwrite this one with no<br/>error from either side.<br/><br/>The module does **not** create public buckets: the public access block is always<br/>on. To serve static web content you use [`modules/site`](../site), which puts<br/>CloudFront in front of a private bucket with Origin Access Control.<br/><br/>A public bucket behind CloudFront makes CloudFront bypassable: anyone who knows the<br/>bucket's name can read the objects from the S3 endpoint, skipping WAF, logging and<br/>the cache. | `string` | `null` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, typically `<project>-<environment>`. | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |
| <a name="input_versioning_enabled"></a> [versioning\_enabled](#input\_versioning\_enabled) | Object versioning. **Enabled by default**: it is the only protection against a<br/>wrong application-level overwrite or deletion, and there is no way to recover an<br/>object without it.<br/><br/>It costs in storage, which you keep in check with a `lifecycle_rules` entry that<br/>expires the non-current versions. | `bool` | `true` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_arn"></a> [arn](#output\_arn) | The bucket's ARN. |
| <a name="output_domain_name"></a> [domain\_name](#output\_domain\_name) | The bucket's domain name. |
| <a name="output_id"></a> [id](#output\_id) | The bucket's ID (identical to the name). |
| <a name="output_name"></a> [name](#output\_name) | The bucket's name, already prefixed. |
| <a name="output_notification_ids"></a> [notification\_ids](#output\_notification\_ids) | The ids of the configured notifications, by destination. Used to verify they converged into a single configuration. |
| <a name="output_policy_json_attached"></a> [policy\_json\_attached](#output\_policy\_json\_attached) | Whether the `policy_json` passed in takes part in the bucket's policy.<br/><br/>The bucket always has one — the TLS statements are unconditional — so this reports the<br/>caller's document alone, which is the part that a duplicate `aws_s3_bucket_policy`<br/>elsewhere would silently replace. |
| <a name="output_regional_domain_name"></a> [regional\_domain\_name](#output\_regional\_domain\_name) | The regional domain name, the one to use as a CloudFront origin. |
| <a name="output_registry_entry"></a> [registry\_entry](#output\_registry\_entry) | The entry to put into the consumers' `resources` registry, already in the expected<br/>shape, CMK included.<br/><br/>    resources = { buckets = { documents = module.documents.registry\_entry } } |
| <a name="output_static_arn"></a> [static\_arn](#output\_static\_arn) | The ARN computed from the name, without depending on the resource.<br/><br/>It is there to break cycles: a queue receiving notifications from this bucket has to<br/>authorize `s3.amazonaws.com` with the bucket's ARN as a condition, but the bucket<br/>needs the queue's ARN for the notification. Using this output — or the equivalent<br/>string — the queue does not depend on the bucket. |
<!-- END_TF_DOCS -->
