# topic

An SNS topic with its non-SQS subscriptions, the service publishers' policy and the alarm on failed
deliveries. It wraps [`terraform-aws-modules/sns/aws`](https://github.com/terraform-aws-modules/terraform-aws-sns)
`~> 6.0`.

## Usage

```hcl
module "operations" {
  source = "…//modules/topic"

  prefix = "acme-prod"
  name   = "operations"

  subscriptions = {
    processor = { protocol = "lambda", endpoint = module.processor.arn }
    oncall    = { protocol = "email",  endpoint = "oncall@acme.example" }
  }
}
```

And in the publisher:

```hcl
module "api" {
  source = "…//modules/function"

  resources = { topics = { operations = module.operations.registry_entry } }
  grants    = { "topic/operations" = ["publish"] }
  env_from  = { OPERATIONS_TOPIC = { topic = "operations" } }
}
```

## Subscriptions towards SQS do not live here

`subscriptions` accepts `lambda`, `email`, `https`, `sms`, `firehose`, `application` — and **rejects
`sqs`**, stopping the plan with a message pointing at [`modules/queue`](../queue).

This is not pedantry. SQS allows a single `Policy` attribute per queue: with several topics publishing
onto the same queue you need one document with one statement per topic, and the only place that can be
guaranteed from is the queue. Declaring them on the topic side works as long as there is a single topic
and breaks silently at the second one — which is exactly the regression that already happened in the
wiring this library grew out of.

## The KMS trap with service publishers

The topic is encrypted by default with the AWS-managed key (`alias/aws/sns`), which has no cost. But
**AWS services cannot use that key**: an S3 notification or an EventBridge rule towards a topic
encrypted with `alias/aws/sns` fails with a `KMSAccessDenied` that appears nowhere in Terraform — the
message is lost and there is no trace.

The module **stops the plan** if you declare `allow_publish_from` without a CMK, and the message says
what to do:

```hcl
encryption = { kms_key_id = aws_kms_key.sns.arn }   # with a key policy authorizing the service
allow_publish_from = [
  { service = "s3", source_arn = "arn:aws:s3:::acme-prod-documents" },
]
```

The alternative, if encryption is not needed, is `encryption = { managed = false }` — but it has to be
chosen, not suffered.

## Opinionated defaults

| | module default | AWS default | why |
|---|---|---|---|
| encryption | enabled (`alias/aws/sns`) | absent | zero cost, and a topic in the clear is a default not a decision |
| topic policy | **not created** | not created | without a policy only the account owner publishes; creating one to say nothing is noise |
| alarm on failed deliveries | enabled | absent | see below |

## Alarms

`NumberOfNotificationsFailed`, threshold **one** notification. It is the only signal available: SNS
retries deliveries according to the delivery policy and then discards the message, without informing the
publisher. Without this alarm the loss is completely invisible.

`treat_missing_data = "notBreaching"`: a topic with no traffic publishes no metrics.

## Notes

- Do not add `.fifo` to the name: the module composes it from `fifo.enabled`.
- Every `allow_publish_from` entry must have `source_arn` or `source_account`. Without a condition the
  policy would authorize any resource of that service in any account: it is the kind of mistake that goes
  unnoticed until the audit.
- Fan-out towards Lambda also needs an `aws_lambda_permission` on the function: that is handled by
  [`modules/function`](../function) through `allowed_triggers`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_sns"></a> [sns](#module\_sns) | terraform-aws-modules/sns/aws | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_metric_alarm.failed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | The topic's name, without the `.fifo` suffix (the module adds it). If `prefix` is set the final name is `<prefix>-<name>`. | `string` | n/a | yes |
| <a name="input_alarms"></a> [alarms](#input\_alarms) | Alarms on undelivered notifications.<br/><br/>`NumberOfNotificationsFailed` is the only signal that a delivery is failing: SNS<br/>retries and then drops the message, without the publisher knowing anything about<br/>it. The threshold is **one** notification. | <pre>object({<br/>    enabled          = optional(bool, true)<br/>    actions          = optional(list(string), [])<br/>    ok_actions       = optional(list(string), [])<br/>    failed_threshold = optional(number, 1)<br/>    failed_period    = optional(number, 300)<br/>  })</pre> | `{}` | no |
| <a name="input_allow_publish_from"></a> [allow\_publish\_from](#input\_allow\_publish\_from) | AWS services authorized to publish to this topic — S3 notifications, EventBridge<br/>rules, CloudWatch alarms.<br/><br/>Every entry must have `source_arn` or `source_account`: without a condition the<br/>policy would authorize any resource of that service in any account.<br/><br/>`source_arn` must be passed as a literal string and not as a reference to the<br/>resource when the resource in turn depends on this topic — a notifying bucket, for<br/>example: that would be a cycle between the two modules. | <pre>list(object({<br/>    service        = string<br/>    source_arn     = optional(string)<br/>    source_account = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_archive_policy"></a> [archive\_policy](#input\_archive\_policy) | Archive policy JSON, for message replay on FIFO topics. | `string` | `null` | no |
| <a name="input_delivery_policy"></a> [delivery\_policy](#input\_delivery\_policy) | The topic's delivery policy JSON, for retry policies on HTTP destinations. | `string` | `null` | no |
| <a name="input_display_name"></a> [display\_name](#input\_display\_name) | Display name, used as the sender in email and SMS notifications. | `string` | `null` | no |
| <a name="input_encryption"></a> [encryption](#input\_encryption) | Encryption at rest. Enabled by default with the AWS-managed key<br/>(`alias/aws/sns`), which has no cost: a topic in the clear is AWS's default, not a<br/>choice.<br/><br/>**Careful with service publishers.** S3, EventBridge and the other AWS services<br/>cannot use the AWS-managed key: publishing to a topic encrypted with<br/>`alias/aws/sns` from a bucket fails with a `KMSAccessDenied` that appears nowhere<br/>in Terraform. Those cases need a CMK with a key policy that authorizes the service<br/>— and the module stops the plan if you declare `allow_publish_from` without one. | <pre>object({<br/>    managed    = optional(bool, true)<br/>    kms_key_id = optional(string)<br/>  })</pre> | `{}` | no |
| <a name="input_extra_policy_statements"></a> [extra\_policy\_statements](#input\_extra\_policy\_statements) | Additional statements for the topic's policy, in the format the upstream module accepts. | `map(any)` | `{}` | no |
| <a name="input_fifo"></a> [fifo](#input\_fifo) | FIFO configuration. With `enabled = true` the name receives the `.fifo` suffix. | <pre>object({<br/>    enabled                     = optional(bool, false)<br/>    content_based_deduplication = optional(bool, false)<br/>    throughput_scope            = optional(string)<br/>  })</pre> | `{}` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, typically `<project>-<environment>`. | `string` | `null` | no |
| <a name="input_subscriptions"></a> [subscriptions](#input\_subscriptions) | The topic's subscriptions towards destinations **other than SQS**: lambda, email,<br/>https, sms, firehose, application.<br/><br/>Subscriptions towards SQS are declared on [`modules/queue`](../queue), not here.<br/>SQS allows a single `Policy` attribute per queue: with several topics publishing<br/>onto the same queue you need one document with one statement per topic, and the<br/>only place that can be guaranteed from is the queue. Declaring them here would<br/>leave only the last policy written alive, with no errors.<br/><br/>    subscriptions = {<br/>      processor = { protocol = "lambda", endpoint = module.processor.arn }<br/>      oncall    = { protocol = "email",  endpoint = "oncall@acme.example" }<br/>    } | <pre>map(object({<br/>    protocol              = string<br/>    endpoint              = string<br/>    filter_policy         = optional(string)<br/>    filter_policy_scope   = optional(string, "MessageAttributes")<br/>    raw_message_delivery  = optional(bool)<br/>    delivery_policy       = optional(string)<br/>    redrive_policy        = optional(string)<br/>    replay_policy         = optional(string)<br/>    subscription_role_arn = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |
| <a name="input_tracing_config"></a> [tracing\_config](#input\_tracing\_config) | Propagation of X-Ray traces through the topic. 'Active' to propagate, 'PassThrough' to generate no segments. | `string` | `"PassThrough"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alarm_arns"></a> [alarm\_arns](#output\_alarm\_arns) | The created alarms' ARNs, by type. An empty map when the alarms are disabled. |
| <a name="output_arn"></a> [arn](#output\_arn) | The topic's ARN. |
| <a name="output_id"></a> [id](#output\_id) | The topic's ID. |
| <a name="output_name"></a> [name](#output\_name) | The topic's name, already prefixed and with the .fifo suffix if FIFO. |
| <a name="output_policy_statement_sids"></a> [policy\_statement\_sids](#output\_policy\_statement\_sids) | The Sids of the statements in the topic's policy, sorted. Empty when there are no service publishers and AWS's default applies. |
| <a name="output_registry_entry"></a> [registry\_entry](#output\_registry\_entry) | The entry to put into the publishers' `resources` registry, already in the expected<br/>shape, CMK included.<br/><br/>    resources = { topics = { events = module.events.registry\_entry } } |
| <a name="output_subscription_arns"></a> [subscription\_arns](#output\_subscription\_arns) | The created subscriptions' ARNs, by key. |
<!-- END_TF_DOCS -->
