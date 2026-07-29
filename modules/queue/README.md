# queue

An SQS queue with its dead letter queue, the redrive configured, the sources' policy and the alarms.
It wraps [`terraform-aws-modules/sqs/aws`](https://github.com/terraform-aws-modules/terraform-aws-sqs)
`~> 5.0`.

## Usage

```hcl
module "jobs" {
  source = "…//modules/queue"

  prefix = "acme-prod"
  name   = "jobs"

  # At least the consumer's timeout, better six times as much
  visibility_timeout_seconds = 180

  subscriptions = {
    operations = { topic_arn = module.operations.arn }
    audit      = { topic_arn = module.audit.arn, filter_policy = jsonencode({ severity = ["critical"] }) }
  }

  alarms = {
    actions = [module.alerts.arn]
  }
}
```

And in the consumer:

```hcl
module "worker" {
  source = "…//modules/function"

  resources     = { queues = { jobs = module.jobs.registry_entry } }
  grants        = { "queue/jobs" = ["consume"] }
  event_sources = { jobs = { queue = "jobs" } }
}
```

`registry_entry` returns the entry already in the shape the registry expects, **CMK included**.
Recomposing it by hand is the typical way of forgetting `kms_key_arn`, which produces an `AccessDenied`
on KMS at runtime while the policy on SQS is perfect.

## Subscriptions live on the queue side

`subscriptions` declares **which topics publish onto this queue**, not the other way around. This is not
a matter of taste: SQS allows **a single `Policy` attribute per queue**. With three topics publishing
onto the same queue you need one document with three statements; declared on the topic side, every topic
would try to write its own policy onto the queue and only the last write would survive, without any
error.

It is a regression that really happened in the wiring this library grew out of, fixed by hand by grouping
the subscriptions per queue. Here the grouping is unnecessary, because the queue is already the place
where you declare.

`modules/app` will keep accepting the DSL written on the topic side and inverting it: it is a pure
transformation, and the right place for it is the composition, not the primitive.

## Opinionated defaults

| | module default | AWS default | why |
|---|---|---|---|
| DLQ | **enabled** | absent | without a DLQ a failing message stays in the queue until it expires and then disappears |
| `max_receive_count` | 5 | — | without it the redrive is not configured at all and the DLQ stays empty forever |
| DLQ retention | 14 days | 4 days | if a message ended up in a DLQ, you need the time to notice and reprocess it |
| `receive_wait_time_seconds` | 20 | 0 | short polling pays for many more empty requests and adds latency |
| encryption | enabled (SSE-SQS) | absent | a queue in the clear is AWS's default, not a decision |
| alarms | enabled | absent | see below |

`visibility_timeout_seconds` stays at 30 seconds as on AWS, because the correct value depends on the
consumer: it must be raised to at least its timeout, otherwise the message becomes visible again while it
is still being worked on and gets processed twice.

## Alarms

- **Age of the oldest message** (`ApproximateAgeOfOldestMessage`, 300s by default). This is the signal
  that tells you whether the consumers are keeping up. Queue depth is not: it grows for a traffic spike
  absorbed perfectly well too.
- **Non-empty DLQ** (`ApproximateNumberOfMessagesVisible >= 1`). The threshold is **one** message:
  anything in a DLQ is an incident, not a metric to watch.

Both use `treat_missing_data = "notBreaching"`: an empty queue publishes no metrics, and an alarm
permanently in `INSUFFICIENT_DATA` gets ignored.

## Non-SNS sources

`allow_send_from` authorizes other AWS services to write to the queue — S3 notifications, EventBridge
events, on-failure destinations. Every entry **must** have `source_arn` or `source_account`: without a
condition the policy would authorize any resource of that service in any account, and it is a mistake
that goes unnoticed until the audit.

`source_arn` must be passed as a **literal string**, not as a reference to the resource. A bucket
notifying a queue needs the queue's ARN, and the queue needs the bucket's ARN: referring to the resource
would create a cycle between the two modules. S3 ARNs are deterministic from the name, so the string is
safe:

```hcl
allow_send_from = [
  { service = "s3", source_arn = "arn:aws:s3:::acme-prod-documents" },
]
```

## Notes

- Do not add `.fifo` to the name: the module composes it from `fifo.enabled`, and applies it to the DLQ
  too as AWS requires.
- The module does not create the event source mappings towards the Lambdas: those live on
  [`modules/function`](../function), which also verifies that the consumer has the `consume` capability.
- The `subscriptions` keys become the policy's `Sid`s, so they only accept alphanumeric characters, `-`
  and `_`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_sqs"></a> [sqs](#module\_sqs) | terraform-aws-modules/sqs/aws | ~> 5.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_metric_alarm.age](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_sns_topic_subscription.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | The queue's name, without the `.fifo` suffix (the module adds it). If `prefix` is set the final name is `<prefix>-<name>`. | `string` | n/a | yes |
| <a name="input_alarms"></a> [alarms](#input\_alarms) | Alarms on the queue and the DLQ.<br/><br/>`age_threshold_seconds` watches the age of the oldest message: it is the signal<br/>that tells you whether the consumers are keeping up, far more useful than the<br/>queue's depth, which grows for a mere traffic spike too.<br/><br/>On the DLQ the threshold is **one** message: any message in a DLQ is an incident,<br/>not a metric to keep an eye on. | <pre>object({<br/>    enabled               = optional(bool, true)<br/>    actions               = optional(list(string), [])<br/>    ok_actions            = optional(list(string), [])<br/>    age_threshold_seconds = optional(number, 300)<br/>    age_period            = optional(number, 300)<br/>    dlq_threshold         = optional(number, 1)<br/>    dlq_period            = optional(number, 300)<br/>  })</pre> | `{}` | no |
| <a name="input_allow_send_from"></a> [allow\_send\_from](#input\_allow\_send\_from) | AWS services authorized to send messages to this queue, beyond the topics declared<br/>in `subscriptions`. Needed for S3 notifications, EventBridge events and the<br/>on-failure destinations of other services.<br/><br/>`source_arn` must be passed as a **string**, not as a reference to the resource: a<br/>bucket notifying a queue needs the queue's ARN, and the queue needs the bucket's<br/>ARN. Referring to the resource would create a cycle between the two modules. S3<br/>ARNs are deterministic from the name, so the string is safe.<br/><br/>    allow\_send\_from = [<br/>      { service = "s3", source\_arn = "arn:aws:s3:::acme-prod-documents" },<br/>      { service = "events", source\_account = "111122223333" },<br/>    ] | <pre>list(object({<br/>    service        = string<br/>    source_arn     = optional(string)<br/>    source_account = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_delay_seconds"></a> [delay\_seconds](#input\_delay\_seconds) | Delivery delay applied to every message. | `number` | `0` | no |
| <a name="input_dlq"></a> [dlq](#input\_dlq) | Dead letter queue.<br/><br/>Enabled by default: without a DLQ a message that fails repeatedly stays in the<br/>queue until it expires and then disappears, with nobody noticing.<br/>`max_receive_count` is the part the previous wiring did not expose at all — without<br/>it the redrive is not configured and the DLQ stays empty forever.<br/><br/>The DLQ's retention is 14 days by default: if a message ended up there, you need<br/>the time to notice and to reprocess it. | <pre>object({<br/>    enabled                    = optional(bool, true)<br/>    max_receive_count          = optional(number, 5)<br/>    message_retention_seconds  = optional(number, 1209600)<br/>    visibility_timeout_seconds = optional(number)<br/>  })</pre> | `{}` | no |
| <a name="input_encryption"></a> [encryption](#input\_encryption) | Encryption at rest. Enabled by default with the SQS-managed key: a queue in the<br/>clear is AWS's default, not a choice.<br/><br/>Setting `kms_key_id` switches to a CMK. In that case remember to pass the same key<br/>in the consumers' resource registry, so that the KMS permissions are generated<br/>automatically from the grants. | <pre>object({<br/>    managed                           = optional(bool, true)<br/>    kms_key_id                        = optional(string)<br/>    kms_data_key_reuse_period_seconds = optional(number)<br/>  })</pre> | `{}` | no |
| <a name="input_extra_policy_statements"></a> [extra\_policy\_statements](#input\_extra\_policy\_statements) | Additional statements for the queue's policy, in the format the upstream module accepts. | <pre>map(object({<br/>    sid           = optional(string)<br/>    effect        = optional(string, "Allow")<br/>    actions       = optional(list(string))<br/>    not_actions   = optional(list(string))<br/>    resources     = optional(list(string))<br/>    not_resources = optional(list(string))<br/>    principals = optional(list(object({<br/>      type        = string<br/>      identifiers = list(string)<br/>    })))<br/>    condition = optional(list(object({<br/>      test     = string<br/>      variable = string<br/>      values   = list(string)<br/>    })))<br/>  }))</pre> | `{}` | no |
| <a name="input_fifo"></a> [fifo](#input\_fifo) | FIFO configuration. With `enabled = true` the queue's name receives the `.fifo`<br/>suffix and the DLQ becomes FIFO too, as AWS requires. | <pre>object({<br/>    enabled                     = optional(bool, false)<br/>    content_based_deduplication = optional(bool, false)<br/>    deduplication_scope         = optional(string)<br/>    throughput_limit            = optional(string)<br/>  })</pre> | `{}` | no |
| <a name="input_max_message_size"></a> [max\_message\_size](#input\_max\_message\_size) | Maximum message size in bytes. | `number` | `262144` | no |
| <a name="input_message_retention_seconds"></a> [message\_retention\_seconds](#input\_message\_retention\_seconds) | How long an unconsumed message stays in the queue. AWS default: 4 days. | `number` | `345600` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, typically `<project>-<environment>`. | `string` | `null` | no |
| <a name="input_receive_wait_time_seconds"></a> [receive\_wait\_time\_seconds](#input\_receive\_wait\_time\_seconds) | Long polling. This module's default is 20 seconds, not AWS's zero: with short<br/>polling you pay for many more empty requests and add pointless latency to delivery. | `number` | `20` | no |
| <a name="input_subscriptions"></a> [subscriptions](#input\_subscriptions) | SNS topics that publish onto this queue.<br/><br/>The subscriptions are declared **on the queue side** and not on the topic side for<br/>a precise reason: SQS allows a single `Policy` attribute per queue, so with several<br/>topics publishing onto the same queue you need one document with one statement per<br/>topic. Declared on the topic side, every topic would try to write its own policy<br/>and only the last one would survive, silently.<br/><br/>    subscriptions = {<br/>      events = { topic\_arn = module.events.arn }<br/>      audit  = { topic\_arn = module.audit.arn, filter\_policy = jsonencode({ type = ["critical"] }) }<br/>    } | <pre>map(object({<br/>    topic_arn            = string<br/>    filter_policy        = optional(string)<br/>    filter_policy_scope  = optional(string, "MessageAttributes")<br/>    raw_message_delivery = optional(bool, false)<br/>  }))</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |
| <a name="input_visibility_timeout_seconds"></a> [visibility\_timeout\_seconds](#input\_visibility\_timeout\_seconds) | How long a message being processed stays invisible.<br/><br/>It must be set to at least the timeout of the consuming function, otherwise the<br/>message becomes visible again while it is still being worked on and gets processed<br/>twice. A rule of thumb is six times the function's timeout. | `number` | `30` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alarm_arns"></a> [alarm\_arns](#output\_alarm\_arns) | The created alarms' ARNs, by type. An empty map when the alarms are disabled. |
| <a name="output_arn"></a> [arn](#output\_arn) | The queue's ARN. |
| <a name="output_dlq_arn"></a> [dlq\_arn](#output\_dlq\_arn) | The DLQ's ARN. Null when the DLQ is disabled. |
| <a name="output_dlq_name"></a> [dlq\_name](#output\_dlq\_name) | The DLQ's name. Null when the DLQ is disabled. |
| <a name="output_dlq_url"></a> [dlq\_url](#output\_dlq\_url) | The DLQ's URL, to reprocess the messages that ended up there. Null when the DLQ is disabled. |
| <a name="output_id"></a> [id](#output\_id) | The queue's ID. |
| <a name="output_name"></a> [name](#output\_name) | The queue's name, already prefixed and with the .fifo suffix if FIFO. |
| <a name="output_policy_statement_sids"></a> [policy\_statement\_sids](#output\_policy\_statement\_sids) | The Sids of the statements in the queue's policy, sorted. Used to verify that fan-in from several sources converged into a single document. |
| <a name="output_registry_entry"></a> [registry\_entry](#output\_registry\_entry) | The entry to put into the consumers' `resources` registry, already in the expected<br/>shape. It saves you from recomposing it by hand and forgetting the CMK, which is<br/>what makes the KMS permissions fail at runtime while the policy on the service is<br/>perfect.<br/><br/>    resources = { queues = { jobs = module.jobs.registry\_entry } } |
| <a name="output_url"></a> [url](#output\_url) | The queue's URL, the one the SDKs need to receive and send. |
<!-- END_TF_DOCS -->
