# observability

The alarm topic, the application's dashboard, log forwarding to an external destination and a composite
alarm.

It is the only module that is declared **before** the others: its `alarm_topic_arn` is what the other
modules expect in `alarms.actions`.

## Usage

```hcl
module "observability" {
  source = "…//modules/observability"

  prefix = "acme-prod"
  name   = "app"

  alarm_topic = {
    subscriptions = {
      oncall = { protocol = "email", endpoint = "oncall@acme.example" }
    }
  }

  functions = [module.api.name, module.worker.name]
  queues    = [module.jobs.name, module.jobs.dlq_name]
  tables    = [module.tenants.name]
  apis      = [{ id = module.api_gw.id }]

  log_shipping = {
    destination_arn = var.loki_firehose_arn
    role_arn        = var.log_shipping_role_arn
    filter_pattern  = "{ $.level = \"error\" }"
    log_groups      = [module.api.log_group_name, module.worker.log_group_name]
  }
}
```

And in the other modules:

```hcl
module "jobs" {
  source = "…//modules/queue"
  alarms = { actions = [module.observability.alarm_topic_arn] }
}
```

## The alarm topic is not encrypted by default

Unlike [`modules/topic`](../topic), here encryption is **disabled**.

CloudWatch cannot use the AWS-managed key: with `alias/aws/sns` the alarms do not arrive. And the failure
is particularly insidious, because **an alarm that fails to notify does not itself raise an alarm**: the
system looks watched and it is not.

To encrypt it you need a CMK whose key policy authorizes `cloudwatch.amazonaws.com`. In that case you pass
`alarm_topic.kms_key_id`.

## Dashboard

The widgets are built **per resource type**, not per resource: one error line with all the functions
overlaid shows at once which one is failing, whereas twenty separate widgets have to be hunted through one
by one. Two widgets per type, laid out in two columns.

| type | widgets |
|---|---|
| API | requests, `5xx`, `4xx` — and p99 latency |
| Lambda | errors and throttles — and p99 duration |
| SQS | age of the oldest message — and visible messages |
| DynamoDB | read and write throttles — and consumed capacity |

For SQS it is worth including the **DLQs** too: that is where you see whether something is failing.

With no declared resources the dashboard is not created: an empty dashboard takes up one of the account's
three free ones without showing anything.

## Composite alarm

`composite_alarm` creates a single alarm that fires when at least one of the listed ones is in alarm.

It is there to cut the noise. With twenty alarms on an application one incident lights up six of them, and
whoever is on call receives six notifications for a single problem — which is how notifications start being
ignored. The composite alarm notifies once; the individual ones stay for the diagnosis.

It requires at least two alarms: with only one it adds a layer of indirection without reducing anything.

## Log forwarding

`log_shipping` creates one subscription filter per log group towards an external destination — typically a
Firehose or a Lambda that writes to Loki.

`role_arn` is needed for Firehose and Kinesis destinations. For a Lambda what is needed instead is an
`aws_lambda_permission` on the destination function, which this module does **not** create, because the
function may live in another account.

An empty `filter_pattern` forwards everything. It is worth narrowing it down: forwarding is billed by
volume, and the debug logs of a verbose Lambda cost more than they are worth.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_alarm_topic"></a> [alarm\_topic](#module\_alarm\_topic) | ../topic | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_composite_alarm.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_composite_alarm) | resource |
| [aws_cloudwatch_dashboard.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_dashboard) | resource |
| [aws_cloudwatch_log_subscription_filter.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_subscription_filter) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | Name of the observed application. If `prefix` is set the final name is `<prefix>-<name>`. | `string` | n/a | yes |
| <a name="input_alarm_topic"></a> [alarm\_topic](#input\_alarm\_topic) | The SNS topic to deliver the alarms to. Its ARN then has to be passed to every other<br/>module's `alarms.actions` — which is why this module is declared **before** the others.<br/><br/>**Encryption is disabled by default**, unlike in `modules/topic`. CloudWatch cannot use<br/>the AWS-managed key: with `alias/aws/sns` the alarms would not arrive, and the failure<br/>is silent because an alarm that fails to notify does not itself raise an alarm. To<br/>encrypt it you need a CMK whose key policy authorizes `cloudwatch.amazonaws.com`. | <pre>object({<br/>    create     = optional(bool, true)<br/>    kms_key_id = optional(string)<br/>    subscriptions = optional(map(object({<br/>      protocol = string<br/>      endpoint = string<br/>    })), {})<br/>  })</pre> | `{}` | no |
| <a name="input_apis"></a> [apis](#input\_apis) | HTTP API Gateways to include in the dashboard, with their id and stage. | <pre>list(object({<br/>    id    = string<br/>    stage = optional(string, "$default")<br/>  }))</pre> | `[]` | no |
| <a name="input_composite_alarm"></a> [composite\_alarm](#input\_composite\_alarm) | A composite alarm that fires when at least one of the listed alarms is in alarm.<br/><br/>It is there to cut the noise: with twenty alarms on an application, one incident lights<br/>up six of them and whoever is on call receives six notifications for a single problem.<br/>The composite alarm notifies once, and the individual ones stay for the diagnosis. | <pre>object({<br/>    enabled    = optional(bool, false)<br/>    alarm_arns = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| <a name="input_dashboard_enabled"></a> [dashboard\_enabled](#input\_dashboard\_enabled) | Creates a CloudWatch dashboard with the declared resources. Dashboards are free up to three per account, then they carry a monthly cost. | `bool` | `true` | no |
| <a name="input_existing_alarm_topic_arn"></a> [existing\_alarm\_topic\_arn](#input\_existing\_alarm\_topic\_arn) | ARN of an already existing topic to use instead of creating one. Requires `alarm_topic.create = false`. | `string` | `null` | no |
| <a name="input_functions"></a> [functions](#input\_functions) | Names of the Lambda functions to include in the dashboard. | `list(string)` | `[]` | no |
| <a name="input_log_shipping"></a> [log\_shipping](#input\_log\_shipping) | Forwarding of the logs to an external destination — typically a Firehose or a Lambda<br/>that writes to Loki.<br/><br/>`role_arn` is required for Firehose and Kinesis destinations, not for a Lambda: in the<br/>latter case what is needed instead is an `aws_lambda_permission` on the destination<br/>function, which this module does not create because the function may live in another<br/>account.<br/><br/>An empty `filter_pattern` forwards everything. It is worth narrowing it down:<br/>forwarding is billed by volume and the debug logs of a verbose Lambda cost more than<br/>they are worth. | <pre>object({<br/>    destination_arn = string<br/>    role_arn        = optional(string)<br/>    filter_pattern  = optional(string, "")<br/>    log_groups      = optional(list(string), [])<br/>  })</pre> | `null` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, typically `<project>-<environment>`. | `string` | `null` | no |
| <a name="input_queues"></a> [queues](#input\_queues) | Names of the SQS queues to include in the dashboard. Include the DLQs too: that is where you see whether something is failing. | `list(string)` | `[]` | no |
| <a name="input_region"></a> [region](#input\_region) | Region used in the dashboard's metrics. Null infers it from the provider. | `string` | `null` | no |
| <a name="input_tables"></a> [tables](#input\_tables) | Names of the DynamoDB tables to include in the dashboard. | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alarm_topic_arn"></a> [alarm\_topic\_arn](#output\_alarm\_topic\_arn) | ARN of the alarm topic. To be passed to every other module's `alarms.actions`:<br/><br/>    module "jobs" {<br/>      source = "…//modules/queue"<br/>      alarms = { actions = [module.observability.alarm\_topic\_arn] }<br/>    }<br/><br/>It is the reason this module is declared before the others. |
| <a name="output_composite_alarm_arn"></a> [composite\_alarm\_arn](#output\_composite\_alarm\_arn) | The composite alarm's ARN. Null when it is disabled. |
| <a name="output_dashboard_name"></a> [dashboard\_name](#output\_dashboard\_name) | The dashboard's name. Null when it was not created, for example because no resource was declared. |
| <a name="output_dashboard_widget_count"></a> [dashboard\_widget\_count](#output\_dashboard\_widget\_count) | How many widgets the dashboard contains. Zero means no resources to observe were declared. |
| <a name="output_shipped_log_groups"></a> [shipped\_log\_groups](#output\_shipped\_log\_groups) | The log groups forwarded to the external destination, sorted. |
<!-- END_TF_DOCS -->
