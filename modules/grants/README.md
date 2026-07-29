# grants

Translates permissions declared by intent (`read`, `write`, `scan`, `publish`, `consume`) into an IAM
policy document.

This is a **pure** module: it creates no resources, reads no data sources, declares no provider. It is
tested without credentials and without mocks, and the capability → action table is exposed as an output
so that documentation and external tooling can consume it instead of duplicating it.

## Usage

```hcl
module "grants" {
  source = "…//modules/grants"

  resources = {
    buckets = { documents = { arn = module.documents.arn, name = module.documents.name } }
    tables  = { tenants = { arn = module.tenants.arn, name = module.tenants.name } }
    queues  = { emails = { arn = module.emails.arn, url = module.emails.url } }
    secrets = { mongodb = { arn = module.mongodb.arn, name = module.mongodb.name } }
  }

  grants = {
    "bucket/documents" = ["read", "write"]
    "table/tenants"    = ["read", "scan"]
    "queue/emails"     = ["consume"]
    "secret/mongodb"   = ["read"]
  }
}

resource "aws_iam_role_policy" "app" {
  count  = module.grants.has_policy ? 1 : 0
  role   = aws_iam_role.app.id
  policy = module.grants.policy_json
}
```

You normally do not call it by hand: `modules/function` does, exposing `grants` in its own interface.
You need it directly when you have to build the role of something that is not a Lambda.

## Capability table

| capability | `bucket` (s3) | `table` (dynamodb) | `topic` (sns) | `queue` (sqs) | `secret` (secretsmanager) |
|---|---|---|---|---|---|
| `read` | `ListBucket` on the bucket, `GetObject` on the objects | `GetItem`, `BatchGetItem`, `Query` on the table and its indexes | — | — | `GetSecretValue`, `DescribeSecret` |
| `write` | `PutObject`, `DeleteObject`, `AbortMultipartUpload` on the objects | `PutItem`, `UpdateItem`, `DeleteItem`, `BatchWriteItem` | — | — | — |
| `scan` | — | `Scan` on the table and its indexes | — | — | — |
| `publish` | — | — | `Publish` | `SendMessage` | — |
| `consume` | — | — | — | `ReceiveMessage`, `DeleteMessage`, `GetQueueAttributes`, `ChangeMessageVisibility` | — |

Three non-obvious properties of the table:

- **`scan` is separate from `read`.** Scanning a large table is a design decision, not a permissions
  detail, and it must be declared. Merging the two capabilities would silently widen the permissions of
  every existing consumer.
- **Bucket and objects are distinct ARNs.** `ListBucket` lives on the bucket's ARN, `GetObject` on
  `arn/*`. Granting both on the same ARN is the classic mistake that produces an ineffective policy with
  no syntax errors.
- **`read` on a table covers the indexes too.** Querying a GSI requires the `arn/index/*` ARN: without
  it the policy looks correct and fails on the first query against an index.

### Implicit KMS permissions

When a resource in `resources` has `kms_key_arn`, the necessary KMS permissions are added on their own:
`kms:Decrypt` for `read`/`scan`/`consume`, plus `kms:GenerateDataKey` for `write`/`publish`. This is the
case where the runtime error is an `AccessDenied` on KMS while the policy on the service is perfect, so
it has been made impossible to forget.

## Why the keys are prefixed by type

`"bucket/documents"` and not `"documents"`: the same name often belongs to different services. In the
real tfvars this library grew out of, an SNS topic `operations` and an SQS queue `operations` exist at
the same time. A flat registry would make them collide, and the collision would be resolved silently in
favour of one of the two.

## What it does not do

- It does not cover the whole of AWS. The table covers the five services of serverless wiring; for SES,
  Bedrock and the rest there is `extra_statements`, which accepts literal statements with conditions.
- It does not generate policies based on tags or on `NotAction`/`NotResource`. If you need that, it is an
  `extra_statements`.
- It does not grant cross-cutting permissions (`logs:*`, X-Ray, VPC): those are `modules/function`'s
  responsibility, which attaches them according to the Lambda's actual configuration.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_extra_statements"></a> [extra\_statements](#input\_extra\_statements) | Literal IAM statements, for services outside the capability table (SES,<br/>Bedrock, third-party services, cases with unusual conditions).<br/><br/>This is a deliberate escape hatch: the capability table covers the five services<br/>of serverless wiring, not the whole of AWS. Do not use it to work around the<br/>capabilities on services that are already covered. | <pre>list(object({<br/>    sid       = optional(string)<br/>    effect    = optional(string, "Allow")<br/>    actions   = list(string)<br/>    resources = list(string)<br/>    condition = optional(list(object({<br/>      test     = string<br/>      variable = string<br/>      values   = list(string)<br/>    })), [])<br/>  }))</pre> | `[]` | no |
| <a name="input_grants"></a> [grants](#input\_grants) | Permissions declared by intent, not as a list of actions.<br/><br/>The keys take the form `<type>/<name>`, where the type is one of `bucket`,<br/>`table`, `topic`, `queue`, `secret` and the name is the resource's key in<br/>`resources`. The type prefix is mandatory because the same name can belong to<br/>different services: a topic `operations` and a queue `operations` coexist<br/>perfectly well.<br/><br/>The values are the capabilities granted. Valid capabilities per type:<br/><br/>  bucket → read, write<br/>  table  → read, write, scan<br/>  topic  → publish<br/>  queue  → publish, consume<br/>  secret → read<br/><br/>Example:<br/><br/>    grants = {<br/>      "bucket/documents" = ["read", "write"]<br/>      "table/tenants"    = ["read", "scan"]<br/>      "queue/emails"     = ["consume"]<br/>    } | `map(list(string))` | `{}` | no |
| <a name="input_resources"></a> [resources](#input\_resources) | The registry of resources that grants and references can point to.<br/><br/>`arn` is always required. `name` and `url` are used to resolve references<br/>(`env_from` in `modules/function`) and are optional here. `kms_key_arn` must be<br/>set when the resource is encrypted with a CMK: in that case the necessary KMS<br/>permissions are added automatically.<br/><br/>The same registry is passed to `modules/grants` and to `modules/function`. | <pre>object({<br/>    buckets = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    tables = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    topics = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    queues = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    secrets = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>  })</pre> | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_capability_matrix"></a> [capability\_matrix](#output\_capability\_matrix) | The capability → action table, exposed as data. Terraform does not need it: it is<br/>for anyone who has to read it or invert it from the outside — documentation,<br/>audits, conversion tooling — without duplicating it and watching it drift. |
| <a name="output_granted_arns"></a> [granted\_arns](#output\_granted\_arns) | The ARNs actually referenced by the statements generated from the grants, per resource. Used by the tests and by anyone who needs to check what a policy really grants. |
| <a name="output_has_policy"></a> [has\_policy](#output\_has\_policy) | `true` when at least one statement exists. Useful as a `count`/`for_each` in the caller. |
| <a name="output_policy_json"></a> [policy\_json](#output\_policy\_json) | The IAM policy document as JSON, or `null` when there are no statements. The<br/>null is meaningful: attaching a policy with an empty `Statement` is an error on<br/>the AWS side, so the caller must treat its absence as "no policy to create". |
| <a name="output_reference_types"></a> [reference\_types](#output\_reference\_types) | Map of type prefixes to IAM service and child ARN suffix. Used to compose or interpret grant keys from the outside. |
| <a name="output_statements"></a> [statements](#output\_statements) | The statements in structured form, to compose larger policies or to inspect them in tests. |
<!-- END_TF_DOCS -->
