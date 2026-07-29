# function

A Lambda function with its role, log group, event source mappings, asynchronous invocation
configuration and alarms. It is the library's hub module: every other primitive produces resources that
a function consumes.

It wraps [`terraform-aws-modules/lambda/aws`](https://github.com/terraform-aws-modules/terraform-aws-lambda)
`~> 8.0` and adds the typed contract, capability-derived IAM and observability.

## Usage

```hcl
module "api" {
  source = "…//modules/function"

  prefix  = "acme-prod"
  name    = "api"
  package = { local_path = "dist/api.zip" }
  timeout = 29

  resources = local.resources   # the shared registry, see below

  env = {
    LOG_LEVEL = "info"
  }

  env_from = {
    DOCUMENTS_BUCKET = { bucket = "documents" }
    TENANTS_TABLE    = { table  = "tenants" }
    EVENTS_TOPIC     = { topic  = "events" }
    DATABASE_SECRET  = { secret = "database" }
  }

  grants = {
    "bucket/documents" = ["read", "write"]
    "table/tenants"    = ["read"]
    "topic/events"     = ["publish"]
    "secret/database"  = ["read"]
  }
}
```

The `resources` registry is built once and passed to every function:

```hcl
locals {
  resources = {
    buckets = { documents = { arn = module.documents.arn, name = module.documents.name } }
    tables  = { tenants   = { arn = module.tenants.arn, name = module.tenants.name } }
    queues  = { jobs      = { arn = module.jobs.arn, name = module.jobs.name, url = module.jobs.url } }
    topics  = { events    = { arn = module.events.arn, name = module.events.name } }
    secrets = { database  = { arn = module.database.arn, name = module.database.name } }
  }
}
```

See [`examples/function`](../../examples/function) for a complete example with a consumer, a DLQ and
alarms.

## The contract on environment variables

`env` holds literal values, `env_from` references to registry resources. The separation is the module's
central point: **the environment variable's name has no effect whatsoever on the resolution**. Renaming
`BUCKET_DOCUMENTS` to `DOCS` does not touch the infrastructure, and a variable called `SNS_TOPIC_X` can
hold a bucket name if that is what you declare.

The injected attribute has a default per type, chosen on what applications normally expect:

| type | default attribute | why |
|---|---|---|
| `bucket` | `name` | the SDKs address buckets by name |
| `table` | `name` | likewise for DynamoDB |
| `secret` | `name` | `GetSecretValue` accepts the name |
| `topic` | `arn` | `Publish` requires the ARN |
| `queue` | `url` | `ReceiveMessage` and `SendMessage` require the URL |

You override it with `attr`, which accepts `name`, `arn` or `url`.

A reference to a resource that does not exist **stops the plan**, and the message lists the available
resources. A reference to an attribute that exists but is `null` does the same.

## IAM

Permissions are declared with `grants`, translated into policies by [`modules/grants`](../grants), which
documents the capability table. On top of those, the module attaches the cross-cutting permissions on its
own, based on the function's **actual** configuration:

| permission | when |
|---|---|
| CloudWatch logs | always |
| network (ENI) | only if `vpc` is set |
| X-Ray | only if `observability.tracing` is enabled |
| writing to the on-failure destination | only if `async.on_failure` is set |

The conditionality on network permissions corrects a real widening: in the monolith this library grew out
of, the ENI policy was attached to every function, including the 34 that were not in a VPC. The `iam`
output exposes these decisions so they can be checked without reading the state.

## Coherence between consumption and permissions

An event source mapping on a queue requires the `consume` capability on that queue. Without it the module
stops the plan instead of creating a consumer with no permissions — one that would exist, receive nothing
and raise no error at all. It is the class of bug this library exists to make impossible.

The converse is not an error: the `consume` capability without an event source mapping is legitimate, for
example in a worker that polls on its own.

## Observability

Enabled by default, can be disabled:

- **Log group** with explicit retention (7 days by default) and JSON format, so the logs are queryable
  without parsing.
- **X-Ray tracing** in `Active` mode.
- **Three alarms**: errors, throttles and p99 duration. The duration threshold is a fraction of the
  timeout (0.8 by default), not an absolute value: it stays correct when the timeout changes and warns
  *before* the function starts being killed by the timeout. All three use
  `treat_missing_data = "notBreaching"`, because on a low-traffic function the absence of invocations is
  not a fault and an alarm permanently in `INSUFFICIENT_DATA` gets ignored.
- **On-failure destination** for asynchronous invocations. Without a destination an event that exhausts
  its attempts **disappears without a trace**: that is why the asynchronous configuration is enabled by
  default.

### Migrating at parity of resources

Tracing, alarms and the asynchronous configuration are additions relative to an infrastructure that does
not have them, and in a migration they would produce a diff that makes it impossible to tell intended
additions from a translation mistake. For a first pass with an empty diff you turn them off:

```hcl
observability = {
  tracing = false
  alarms  = { enabled = false }
}
async = { enabled = false }
```

Then you turn them back on in a separate PR, where the diff is exactly what you want to read.

## Deploying the code

The module **does not build packages**: the build belongs to CI. `ignore_code_changes` is `true` by
default, consistent with an out-of-band deploy (`aws lambda update-function-code`), so the plan does not
show a diff on every run.

Moving to images with an immutable tag passed by CI, it is worth setting it to `false`: Terraform goes
back to being the truth about which code is deployed, a rollback becomes a `git revert` and promotion
between environments a tag change in a PR.

## Notes

- A `timeout` beyond 29 seconds is pointless behind an HTTP API Gateway: it is the gateway that answers
  504.
- `function_response_types = ["ReportBatchItemFailures"]` is not a default: it enables partial failure
  reporting on SQS, but it requires the handler to return the expected structure. A non-conforming
  handler would make the entire batch be considered failed, so it must be chosen explicitly.
- `managed_policy_arns` and `extra_policy_statements` are escape hatches. If you need them often for the
  same services, the capability table should be extended.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_grants"></a> [grants](#module\_grants) | ../grants | n/a |
| <a name="module_lambda"></a> [lambda](#module\_lambda) | terraform-aws-modules/lambda/aws | ~> 8.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_metric_alarm.duration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.errors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.throttles](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | The function's name. If `prefix` is set the final name is `<prefix>-<name>`. | `string` | n/a | yes |
| <a name="input_allowed_triggers"></a> [allowed\_triggers](#input\_allowed\_triggers) | Invocation permissions (`aws_lambda_permission`) for the services that call this<br/>function: API Gateway, EventBridge, SNS.<br/><br/>Normally `modules/app` populates them from the wiring graph; here they stay<br/>exposed for à-la-carte usage. | <pre>map(object({<br/>    principal     = string<br/>    source_arn    = optional(string)<br/>    action        = optional(string, "lambda:InvokeFunction")<br/>    statement_id  = optional(string)<br/>    principal_org = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_architectures"></a> [architectures](#input\_architectures) | Architecture. arm64 costs less for the same performance on typical workloads. | `list(string)` | <pre>[<br/>  "arm64"<br/>]</pre> | no |
| <a name="input_async"></a> [async](#input\_async) | Behaviour of asynchronous invocations.<br/><br/>`on_failure` is the destination for events that have exhausted their attempts.<br/>Without a destination a failed asynchronous event **disappears without a trace**,<br/>which is why this configuration is enabled by default.<br/><br/>`enabled = false` turns it off entirely: this is for a migration at parity of<br/>resources, where any addition would produce a diff. | <pre>object({<br/>    enabled                      = optional(bool, true)<br/>    maximum_retry_attempts       = optional(number, 2)<br/>    maximum_event_age_in_seconds = optional(number)<br/>    on_failure = optional(object({<br/>      queue = optional(string)<br/>      topic = optional(string)<br/>      arn   = optional(string)<br/>    }))<br/>  })</pre> | `{}` | no |
| <a name="input_description"></a> [description](#input\_description) | The function's description. | `string` | `null` | no |
| <a name="input_env"></a> [env](#input\_env) | Environment variables with a literal value. | `map(string)` | `{}` | no |
| <a name="input_env_from"></a> [env\_from](#input\_env\_from) | Environment variables whose value is a reference to a resource in `resources`,<br/>resolved by the module.<br/><br/>You state the resource's type and key; `attr` picks which attribute to inject and<br/>has a sensible default per type: `name` for buckets, tables and secrets, `arn` for<br/>topics, `url` for queues.<br/><br/>    env\_from = {<br/>      DOCS\_BUCKET = { bucket = "documents" }<br/>      JOBS\_QUEUE  = { queue  = "emails" }<br/>      EVENTS\_ARN  = { topic  = "operations" }<br/>      MONGO\_URI   = { secret = "mongodb" }<br/>    }<br/><br/>The environment variable's name has no effect whatsoever on the resolution: it is<br/>just a name. A reference to a resource that does not exist makes the plan fail. | <pre>map(object({<br/>    bucket = optional(string)<br/>    table  = optional(string)<br/>    topic  = optional(string)<br/>    queue  = optional(string)<br/>    secret = optional(string)<br/>    attr   = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_ephemeral_storage_size"></a> [ephemeral\_storage\_size](#input\_ephemeral\_storage\_size) | Size of /tmp in MB. Null leaves the AWS default of 512. | `number` | `null` | no |
| <a name="input_event_sources"></a> [event\_sources](#input\_event\_sources) | Event source mappings. `queue` is a key in `resources.queues`; alternatively you<br/>pass an explicit `event_source_arn`.<br/><br/>`function_response_types = ["ReportBatchItemFailures"]` enables partial failure<br/>reporting, so that a single problematic message does not make the whole batch be<br/>retried. It is not the default because it requires the handler to return the<br/>expected structure: a non-conforming handler would make the entire batch be<br/>considered failed. | <pre>map(object({<br/>    queue                              = optional(string)<br/>    event_source_arn                   = optional(string)<br/>    enabled                            = optional(bool, true)<br/>    batch_size                         = optional(number)<br/>    maximum_batching_window_in_seconds = optional(number)<br/>    function_response_types            = optional(list(string), [])<br/>    maximum_concurrency                = optional(number)<br/>    filter_patterns                    = optional(list(string), [])<br/>  }))</pre> | `{}` | no |
| <a name="input_extra_policy_statements"></a> [extra\_policy\_statements](#input\_extra\_policy\_statements) | Literal IAM statements, for services outside the capability table (SES, Bedrock, …). | <pre>list(object({<br/>    sid       = optional(string)<br/>    effect    = optional(string, "Allow")<br/>    actions   = list(string)<br/>    resources = list(string)<br/>    condition = optional(list(object({<br/>      test     = string<br/>      variable = string<br/>      values   = list(string)<br/>    })), [])<br/>  }))</pre> | `[]` | no |
| <a name="input_grants"></a> [grants](#input\_grants) | Permissions declared by intent, in the form `<type>/<name> = [capability]`. They<br/>are translated into policies by `modules/grants`, which documents the table.<br/><br/>    grants = {<br/>      "bucket/documents" = ["read", "write"]<br/>      "table/tenants"    = ["read", "scan"]<br/>      "queue/emails"     = ["consume"]<br/>    }<br/><br/>Declaring an `event_sources` entry on a queue **requires** the `consume`<br/>capability on that queue: the module verifies the two sides agree and stops the<br/>plan otherwise. It does not create the mapping as a side effect of the permission<br/>— `consume` alone is legitimate, and is what you want when you poll yourself. | `map(list(string))` | `{}` | no |
| <a name="input_handler"></a> [handler](#input\_handler) | Handler. For the `provided.*` runtimes it is the executable's name. | `string` | `"bootstrap"` | no |
| <a name="input_ignore_code_changes"></a> [ignore\_code\_changes](#input\_ignore\_code\_changes) | Ignore the code hash, so that an out-of-band deploy (CI running<br/>`update-function-code`) does not produce a diff on every plan.<br/><br/>The `true` default reflects the current deploy model. Moving to images with an<br/>immutable tag passed by CI, it is worth setting this to `false`, so that Terraform<br/>goes back to being the truth about the deployed code and a rollback is a revert. | `bool` | `true` | no |
| <a name="input_image_uri"></a> [image\_uri](#input\_image\_uri) | URI of the container image in ECR. Mutually exclusive with `package`. | `string` | `null` | no |
| <a name="input_layers"></a> [layers](#input\_layers) | ARNs of the layers to attach. | `list(string)` | `[]` | no |
| <a name="input_managed_policy_arns"></a> [managed\_policy\_arns](#input\_managed\_policy\_arns) | ARNs of managed policies to attach to the role. An escape hatch: prefer `grants`. | `list(string)` | `[]` | no |
| <a name="input_memory_size"></a> [memory\_size](#input\_memory\_size) | Memory in MB. It also determines the CPU share. | `number` | `128` | no |
| <a name="input_observability"></a> [observability](#input\_observability) | Logs, tracing and alarms. Enabled by default: a function you do not observe is a<br/>function you find out is broken from your users.<br/><br/>`alarms.enabled = false` and `tracing = false` are for a migration at parity of<br/>resources, where any addition would produce a diff.<br/><br/>`duration_threshold_ratio` is the fraction of the timeout beyond which the p99<br/>duration trips the alarm: 0.8 warns before the function starts being killed by the<br/>timeout, not after. | <pre>object({<br/>    log_retention_days = optional(number, 7)<br/>    log_kms_key_id     = optional(string)<br/>    log_format         = optional(string, "JSON")<br/>    log_level          = optional(string)<br/>    system_log_level   = optional(string)<br/>    tracing            = optional(bool, true)<br/>    alarms = optional(object({<br/>      enabled                  = optional(bool, true)<br/>      actions                  = optional(list(string), [])<br/>      ok_actions               = optional(list(string), [])<br/>      error_threshold          = optional(number, 1)<br/>      error_period             = optional(number, 300)<br/>      throttle_threshold       = optional(number, 1)<br/>      throttle_period          = optional(number, 300)<br/>      duration_threshold_ratio = optional(number, 0.8)<br/>      duration_period          = optional(number, 300)<br/>    }), {})<br/>  })</pre> | `{}` | no |
| <a name="input_package"></a> [package](#input\_package) | The function's zip package. Mutually exclusive with `image_uri`.<br/><br/>`local_path` points at an already built zip; `s3_bucket`/`s3_key` at a zip on S3.<br/>The module does not build packages: the build is CI's responsibility. | <pre>object({<br/>    local_path = optional(string)<br/>    s3_bucket  = optional(string)<br/>    s3_key     = optional(string)<br/>  })</pre> | `null` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, typically `<project>-<environment>`. Left null, `name` is used as is. | `string` | `null` | no |
| <a name="input_reserved_concurrent_executions"></a> [reserved\_concurrent\_executions](#input\_reserved\_concurrent\_executions) | Reserved concurrency. -1 means no reservation (uses the account pool). | `number` | `-1` | no |
| <a name="input_resources"></a> [resources](#input\_resources) | The registry of resources referenceable from `env_from`, `grants` and<br/>`event_sources`. The same shape `modules/grants` accepts: build it once and pass<br/>it to both. | <pre>object({<br/>    buckets = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    tables = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    topics = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    queues = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    secrets = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>  })</pre> | `{}` | no |
| <a name="input_runtime"></a> [runtime](#input\_runtime) | Lambda runtime. Ignored for container functions. | `string` | `"provided.al2023"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |
| <a name="input_timeout"></a> [timeout](#input\_timeout) | Timeout in seconds. Behind an HTTP API Gateway the useful limit is 29s; beyond that the gateway answers 504. | `number` | `3` | no |
| <a name="input_vpc"></a> [vpc](#input\_vpc) | VPC configuration. When it is set the module attaches the necessary network<br/>permissions on its own; when it is null it does not attach them at all.<br/><br/>This conditionality is deliberate: giving ENI permissions to a function that is<br/>not in a VPC is a pointless widening of its surface. | <pre>object({<br/>    subnet_ids         = list(string)<br/>    security_group_ids = list(string)<br/>  })</pre> | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alarm_arns"></a> [alarm\_arns](#output\_alarm\_arns) | The created alarms' ARNs, by type. An empty map when the alarms are disabled. |
| <a name="output_arn"></a> [arn](#output\_arn) | The function's ARN. |
| <a name="output_environment_variables"></a> [environment\_variables](#output\_environment\_variables) | The effective environment variables, with the references already resolved. Useful in tests and to understand what the function sees. |
| <a name="output_event_source_mapping_arns"></a> [event\_source\_mapping\_arns](#output\_event\_source\_mapping\_arns) | The event source mappings' ARNs, by key. |
| <a name="output_iam"></a> [iam](#output\_iam) | Which cross-cutting permissions the module decided to attach to the role, based<br/>on the function's actual configuration.<br/><br/>This is not an implementation detail: `network` in particular is the difference<br/>between giving and not giving ENI permissions to a function, and it must be<br/>inspectable without reading the state — from the tests and from comparing<br/>policies during a migration. |
| <a name="output_integration_entry"></a> [integration\_entry](#output\_integration\_entry) | The entry to pass to `modules/http-api` and to `modules/schedule`, already in the<br/>expected shape.<br/><br/>    functions = { api = module.api.integration\_entry }<br/><br/>It contains both `arn` and `invoke_arn` because they serve different purposes:<br/>the API integration wants `invoke_arn`, the invocation permission wants `arn`.<br/>Swapping them produces an error that does not name the cause. |
| <a name="output_invoke_arn"></a> [invoke\_arn](#output\_invoke\_arn) | The invocation ARN, for API Gateway integrations. |
| <a name="output_log_group_arn"></a> [log\_group\_arn](#output\_log\_group\_arn) | The CloudWatch log group's ARN, for subscription filters. |
| <a name="output_log_group_name"></a> [log\_group\_name](#output\_log\_group\_name) | The CloudWatch log group's name. |
| <a name="output_name"></a> [name](#output\_name) | The function's name, already prefixed. |
| <a name="output_policy_json"></a> [policy\_json](#output\_policy\_json) | The policy generated from the grants, for inspection and for tests. Null when there are no grants. |
| <a name="output_qualified_arn"></a> [qualified\_arn](#output\_qualified\_arn) | The published version's ARN. |
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | The execution role's ARN. |
| <a name="output_role_name"></a> [role\_name](#output\_role\_name) | The execution role's name, to attach policies from the outside. |
| <a name="output_version"></a> [version](#output\_version) | The function's published version. |
<!-- END_TF_DOCS -->
