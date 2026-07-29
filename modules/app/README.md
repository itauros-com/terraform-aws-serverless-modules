# app

The composition: it takes the declarative description of a serverless application and instantiates the
primitives, resolving every reference by key.

It is the module a root config calls. The primitives remain usable on their own, but here you get the thing
none of them can give alone: **the wiring**.

## Usage

```hcl
module "app" {
  source = "…//modules/app?ref=v0.1.0"

  prefix = "acme-prod"

  tables  = { tenants = { attributes = { pk = "S" }, hash_key = "pk" } }
  buckets = { documents = {} }
  secrets = { mongodb = {} }

  topics = {
    operations = { to_queues = { events = {} } }
    audit      = { to_queues = { events = { filter_policy = jsonencode({ severity = ["critical"] }) } } }
  }

  queues = {
    events = { visibility_timeout_seconds = 360 }
  }

  functions = {
    files = {
      image    = "${module.registries_url}/files:v1.2.3"
      env      = { LOG_LEVEL = "info" }
      env_from = { DOCS = { bucket = "documents" }, DB = { secret = "mongodb" } }
      grants   = { "bucket/documents" = ["read", "write"], "secret/mongodb" = ["read"] }
    }
    worker = {
      image         = "…/worker:v1.2.3"
      grants        = { "queue/events" = ["consume"] }
      event_sources = { events = { queue = "events", function_response_types = ["ReportBatchItemFailures"] } }
    }
  }

  http_apis = {
    apigw = {
      authorizers = { custom = { type = "lambda", function = "authorizer" } }
      routes = {
        "ANY /files"          = { function = "files", authorizer = "custom" }
        "ANY /files/{proxy+}" = { function = "files", authorizer = "custom" }
      }
    }
  }
}
```

See [`examples/app`](../../examples/app) for a complete configuration.

## What it does that the primitives cannot

**It builds the registry.** Every function receives the same `resources`, composed from the primitives'
outputs. `env_from` and `grants` resolve by key, and a wrong key stops the plan.

**It inverts the subscriptions.** `topics[*].to_queues` reads from the topic side, which is the natural
form. The module inverts it towards the queue side, where SQS requires fan-in from several topics to
converge into a single policy document. It is exactly the work that belongs to a composition: a pure
transformation between the readable form and the correct one.

**It derives route authorization** from the authorizer's type, instead of having it declared twice.

**It creates the alarm topic before everything else** and wires it into every primitive's
`alarms.actions`. There is no such case as an alarm created and delivered to nobody.

**It checks the cross-references all at once.** A plan with four wrong references reports all four, each
with the path of the declaration:

```
Unresolved cross-references:
  - topics['operations'].to_queues references the queue 'evnts', which is not in `queues`
  - queues['ingest'].allow_send_from_buckets references the bucket 'docs', which is not in `buckets`
  - functions['api'].vpc.security_group_keys references the security group 'lambdas', which is not in `security_groups`
  - schedules['cleanup'].target_function references the function 'apy', which is not in `functions`
```

## The bucket ↔ function cycle, and how it is broken

A function can read from a bucket, so it needs its ARN in the registry. A bucket can notify a function, so
it needs its ARN. With real references in both directions Terraform detects a cycle between the two module
blocks and refuses to proceed.

The buckets enter the registry with an **ARN and a name computed from the prefix**, not read from the module
that creates them. S3 ARNs contain neither region nor account, so they are entirely derivable from the name:
the computation is exact, not an approximation. The only consequence is that the function's IAM does not
wait for the bucket's creation, which for a policy is irrelevant.

The same holds for `queues[*].allow_send_from_buckets`: the queue must authorize S3 to write to it, and the
bucket depends on the queue for the notification.

## Creation order

```
alarm_topic → topics → queues ┐
             tables, secrets, ├→ functions → buckets → http_apis, sites, registries, schedules → observability
             security_groups  ┘
```

It is not declared anywhere: it emerges from the references. The buckets come after the functions because
the notifications need them, and the functions do not depend on the buckets because their registry is
computed.

## References by key

Every reference between primitives uses the **map's key**, not an ARN:

| where | references |
|---|---|
| `functions[*].env_from` | `{ bucket = "…" }`, `{ table = "…" }`, `{ topic = "…" }`, `{ queue = "…" }`, `{ secret = "…" }` |
| `functions[*].grants` | `"<type>/<name>" = [capability]` |
| `functions[*].event_sources[*].queue` | key in `queues` |
| `functions[*].vpc.security_group_keys` | keys in `security_groups` |
| `functions[*].async.on_failure_queue` | key in `queues` |
| `topics[*].to_queues` | keys in `queues` |
| `queues[*].allow_send_from_buckets` | keys in `buckets` |
| `buckets[*].notifications.*` | keys in `queues`, `topics`, `functions` |
| `http_apis[*].routes[*].function` | key in `functions` |
| `schedules[*].target_function` / `target_queue` | keys in `functions` / `queues` |
| `registries[*].lambda_read_access_functions` | keys in `functions` |

Nowhere is there a `try(module[...], literal_string)`: that pattern resolves a typo into a string and hands
it to the runtime, which is the silent failure this whole library grew out of.

## Migrating at parity of resources

Tracing, alarms and the asynchronous configuration are additions relative to an infrastructure that does not
have them, and in a migration they would produce a diff that makes it impossible to tell intended additions
from a translation mistake. For a first pass with an empty diff:

```hcl
observability = { enabled = false }

functions = {
  files = {
    observability = { tracing = false, alarms = { enabled = false } }
    async         = { enabled = false }
    …
  }
}
```

Then you turn them back on in a separate PR, where the diff is exactly what you want to read.

## The output to read in a review

```bash
terraform output -json | jq '.app.value.wiring'
```

`wiring` says what is connected to what: the subscriptions that converged onto every queue, every route's
effective authorization, the functions every API can invoke, and what the module decided to attach to every
function's IAM. It is the thing to look at to know which routes are public and which functions have the
network permissions, without working it out from the configuration.

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
| <a name="module_buckets"></a> [buckets](#module\_buckets) | ../bucket | n/a |
| <a name="module_functions"></a> [functions](#module\_functions) | ../function | n/a |
| <a name="module_http_apis"></a> [http\_apis](#module\_http\_apis) | ../http-api | n/a |
| <a name="module_observability"></a> [observability](#module\_observability) | ../observability | n/a |
| <a name="module_queues"></a> [queues](#module\_queues) | ../queue | n/a |
| <a name="module_registries"></a> [registries](#module\_registries) | ../registry | n/a |
| <a name="module_schedules"></a> [schedules](#module\_schedules) | ../schedule | n/a |
| <a name="module_secrets"></a> [secrets](#module\_secrets) | ../secret | n/a |
| <a name="module_security_groups"></a> [security\_groups](#module\_security\_groups) | ../security-group | n/a |
| <a name="module_sites"></a> [sites](#module\_sites) | ../site | n/a |
| <a name="module_tables"></a> [tables](#module\_tables) | ../table | n/a |
| <a name="module_topics"></a> [topics](#module\_topics) | ../topic | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix for every resource, typically `<project>-<environment>`.<br/><br/>It is an input and not a value derived from the workspace: the module knows nothing about<br/>environments, and the choice of which environment it is building belongs to the root config<br/>that calls it. | `string` | n/a | yes |
| <a name="input_buckets"></a> [buckets](#input\_buckets) | S3 buckets. Always private: for static web content you use `sites`.<br/><br/>The notifications reference queues, topics and functions **by key**, not by ARN. | <pre>map(object({<br/>    versioning_enabled = optional(bool, true)<br/>    kms_key_arn        = optional(string)<br/>    force_destroy      = optional(bool, false)<br/>    object_ownership   = optional(string, "BucketOwnerEnforced")<br/><br/>    cors_rules = optional(list(object({<br/>      id              = optional(string)<br/>      allowed_methods = list(string)<br/>      allowed_origins = list(string)<br/>      allowed_headers = optional(list(string))<br/>      expose_headers  = optional(list(string))<br/>      max_age_seconds = optional(number)<br/>    })), [])<br/><br/>    lifecycle_rules = optional(list(object({<br/>      id      = string<br/>      enabled = optional(bool, true)<br/>      filter = optional(object({<br/>        prefix                   = optional(string)<br/>        tags                     = optional(map(string))<br/>        object_size_greater_than = optional(number)<br/>        object_size_less_than    = optional(number)<br/>      }))<br/>      expiration = optional(object({<br/>        days                         = optional(number)<br/>        date                         = optional(string)<br/>        expired_object_delete_marker = optional(bool)<br/>      }))<br/>      noncurrent_version_expiration = optional(object({<br/>        noncurrent_days           = number<br/>        newer_noncurrent_versions = optional(number)<br/>      }))<br/>      transition = optional(list(object({<br/>        days          = number<br/>        storage_class = string<br/>      })), [])<br/>      noncurrent_version_transition = optional(list(object({<br/>        noncurrent_days = number<br/>        storage_class   = string<br/>      })), [])<br/>      abort_incomplete_multipart_upload_days = optional(number)<br/>    })), [])<br/><br/>    notifications = optional(object({<br/>      queues = optional(map(object({<br/>        queue         = string<br/>        events        = list(string)<br/>        filter_prefix = optional(string)<br/>        filter_suffix = optional(string)<br/>      })), {})<br/>      topics = optional(map(object({<br/>        topic         = string<br/>        events        = list(string)<br/>        filter_prefix = optional(string)<br/>        filter_suffix = optional(string)<br/>      })), {})<br/>      functions = optional(map(object({<br/>        function      = string<br/>        events        = list(string)<br/>        filter_prefix = optional(string)<br/>        filter_suffix = optional(string)<br/>      })), {})<br/>    }), {})<br/><br/>    logging = optional(object({<br/>      target_bucket = string<br/>      target_prefix = optional(string)<br/>    }))<br/><br/>    tags = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_functions"></a> [functions](#input\_functions) | Lambda functions.<br/><br/>`env` holds literal values, `env_from` references to resources by key, `grants` the<br/>permissions by intent in the form `<type>/<name> = [capability]`. The environment<br/>variable's name has no effect whatsoever on the resolution.<br/><br/>    functions = {<br/>      files = {<br/>        env      = { LOG\_LEVEL = "info" }<br/>        env\_from = { DOCS = { bucket = "documents" }, DB = { secret = "mongodb" } }<br/>        grants   = { "bucket/documents" = ["read", "write"], "secret/mongodb" = ["read"] }<br/>      }<br/>    } | <pre>map(object({<br/>    description = optional(string)<br/><br/>    image = optional(string)<br/>    package = optional(object({<br/>      local_path = optional(string)<br/>      s3_bucket  = optional(string)<br/>      s3_key     = optional(string)<br/>    }))<br/>    ignore_code_changes = optional(bool, true)<br/><br/>    runtime       = optional(string, "provided.al2023")<br/>    handler       = optional(string, "bootstrap")<br/>    architectures = optional(list(string), ["arm64"])<br/>    layers        = optional(list(string), [])<br/><br/>    memory_size                    = optional(number, 128)<br/>    timeout                        = optional(number, 3)<br/>    ephemeral_storage_size         = optional(number)<br/>    reserved_concurrent_executions = optional(number, -1)<br/><br/>    vpc = optional(object({<br/>      subnet_ids          = list(string)<br/>      security_group_keys = optional(list(string), [])<br/>      security_group_ids  = optional(list(string), [])<br/>    }))<br/><br/>    env = optional(map(string), {})<br/><br/>    env_from = optional(map(object({<br/>      bucket = optional(string)<br/>      table  = optional(string)<br/>      topic  = optional(string)<br/>      queue  = optional(string)<br/>      secret = optional(string)<br/>      attr   = optional(string)<br/>    })), {})<br/><br/>    grants = optional(map(list(string)), {})<br/><br/>    extra_policy_statements = optional(list(object({<br/>      sid       = optional(string)<br/>      effect    = optional(string, "Allow")<br/>      actions   = list(string)<br/>      resources = list(string)<br/>      condition = optional(list(object({<br/>        test     = string<br/>        variable = string<br/>        values   = list(string)<br/>      })), [])<br/>    })), [])<br/><br/>    managed_policy_arns = optional(list(string), [])<br/><br/>    event_sources = optional(map(object({<br/>      queue                              = optional(string)<br/>      event_source_arn                   = optional(string)<br/>      enabled                            = optional(bool, true)<br/>      batch_size                         = optional(number)<br/>      maximum_batching_window_in_seconds = optional(number)<br/>      function_response_types            = optional(list(string), [])<br/>      maximum_concurrency                = optional(number)<br/>      filter_patterns                    = optional(list(string), [])<br/>    })), {})<br/><br/>    async = optional(object({<br/>      enabled                      = optional(bool, true)<br/>      maximum_retry_attempts       = optional(number, 2)<br/>      maximum_event_age_in_seconds = optional(number)<br/>      on_failure_queue             = optional(string)<br/>      on_failure_topic             = optional(string)<br/>    }), {})<br/><br/>    observability = optional(object({<br/>      log_retention_days = optional(number, 7)<br/>      log_kms_key_id     = optional(string)<br/>      log_format         = optional(string, "JSON")<br/>      log_level          = optional(string)<br/>      system_log_level   = optional(string)<br/>      tracing            = optional(bool, true)<br/>      alarms = optional(object({<br/>        enabled                  = optional(bool, true)<br/>        error_threshold          = optional(number, 1)<br/>        error_period             = optional(number, 300)<br/>        throttle_threshold       = optional(number, 1)<br/>        throttle_period          = optional(number, 300)<br/>        duration_threshold_ratio = optional(number, 0.8)<br/>        duration_period          = optional(number, 300)<br/>      }), {})<br/>    }), {})<br/><br/>    tags = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_http_apis"></a> [http\_apis](#input\_http\_apis) | HTTP API Gateways. The routes reference the functions by key. | <pre>map(object({<br/>    description = optional(string)<br/>    stage_name  = optional(string, "$default")<br/><br/>    routes = optional(map(object({<br/>      function               = string<br/>      authorizer             = optional(string)<br/>      authorization_scopes   = optional(list(string), [])<br/>      payload_format_version = optional(string, "2.0")<br/>      timeout_milliseconds   = optional(number)<br/>      throttling_burst_limit = optional(number)<br/>      throttling_rate_limit  = optional(number)<br/>    })), {})<br/><br/>    authorizers = optional(map(object({<br/>      type                    = optional(string, "lambda")<br/>      function                = optional(string)<br/>      identity_sources        = optional(list(string), ["$request.header.Authorization"])<br/>      result_ttl_in_seconds   = optional(number, 0)<br/>      enable_simple_responses = optional(bool, true)<br/>      jwt = optional(object({<br/>        issuer   = string<br/>        audience = list(string)<br/>      }))<br/>    })), {})<br/><br/>    cors = optional(object({<br/>      allow_origins     = optional(list(string), [])<br/>      allow_methods     = optional(list(string), [])<br/>      allow_headers     = optional(list(string), ["content-type", "authorization", "x-amz-date", "x-api-key", "x-amz-security-token"])<br/>      expose_headers    = optional(list(string), [])<br/>      allow_credentials = optional(bool, false)<br/>      max_age           = optional(number)<br/>    }))<br/><br/>    domain = optional(object({<br/>      name            = string<br/>      certificate_arn = optional(string)<br/>      zone_name       = optional(string)<br/>      create_records  = optional(bool, true)<br/>    }))<br/><br/>    throttling = optional(object({<br/>      burst_limit = optional(number, 500)<br/>      rate_limit  = optional(number, 1000)<br/>    }), {})<br/><br/>    access_logs = optional(object({<br/>      enabled         = optional(bool, true)<br/>      retention_days  = optional(number, 30)<br/>      kms_key_id      = optional(string)<br/>      destination_arn = optional(string)<br/>    }), {})<br/><br/>    disable_default_endpoint = optional(bool, false)<br/><br/>    alarms = optional(object({<br/>      enabled                = optional(bool, true)<br/>      server_error_threshold = optional(number, 1)<br/>      server_error_period    = optional(number, 300)<br/>      latency_threshold_ms   = optional(number, 3000)<br/>      latency_period         = optional(number, 300)<br/>    }), {})<br/><br/>    tags = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_observability"></a> [observability](#input\_observability) | Alarm topic, dashboard and log forwarding.<br/><br/>The topic is created **before** the primitives and its ARN is wired automatically into<br/>everyone's `alarms.actions`: there is no way to create an alarm that notifies nobody. | <pre>object({<br/>    enabled = optional(bool, true)<br/><br/>    alarm_topic_kms_key_id = optional(string)<br/>    alarm_subscriptions = optional(map(object({<br/>      protocol = string<br/>      endpoint = string<br/>    })), {})<br/><br/>    dashboard_enabled = optional(bool, true)<br/><br/>    log_shipping = optional(object({<br/>      destination_arn = string<br/>      role_arn        = optional(string)<br/>      filter_pattern  = optional(string, "")<br/>    }))<br/><br/>    composite_alarm_enabled = optional(bool, false)<br/>  })</pre> | `{}` | no |
| <a name="input_queues"></a> [queues](#input\_queues) | SQS queues. Subscriptions from topics are declared on `topics[*].to_queues`.<br/><br/>`allow_send_from_buckets` lists the keys of the buckets authorized to write: the module<br/>resolves the ARN statically from the name, because the bucket depends on the queue for the<br/>notification and a reverse reference would be a cycle. | <pre>map(object({<br/>    fifo = optional(object({<br/>      enabled                     = optional(bool, false)<br/>      content_based_deduplication = optional(bool, false)<br/>      deduplication_scope         = optional(string)<br/>      throughput_limit            = optional(string)<br/>    }), {})<br/><br/>    visibility_timeout_seconds = optional(number, 30)<br/>    message_retention_seconds  = optional(number, 345600)<br/>    receive_wait_time_seconds  = optional(number, 20)<br/>    delay_seconds              = optional(number, 0)<br/>    kms_key_id                 = optional(string)<br/><br/>    dlq = optional(object({<br/>      enabled                    = optional(bool, true)<br/>      max_receive_count          = optional(number, 5)<br/>      message_retention_seconds  = optional(number, 1209600)<br/>      visibility_timeout_seconds = optional(number)<br/>    }), {})<br/><br/>    allow_send_from_buckets = optional(list(string), [])<br/><br/>    allow_send_from = optional(list(object({<br/>      service        = string<br/>      source_arn     = optional(string)<br/>      source_account = optional(string)<br/>    })), [])<br/><br/>    tags = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_registries"></a> [registries](#input\_registries) | ECR repositories for the container functions. | <pre>map(object({<br/>    immutable_tags        = optional(bool, true)<br/>    mutable_tag_patterns  = optional(list(string), ["latest", "dev-*"])<br/>    scan_on_push          = optional(bool, true)<br/>    kms_key_arn           = optional(string)<br/>    force_delete          = optional(bool, false)<br/>    untagged_expire_days  = optional(number, 1)<br/>    keep_tagged_images    = optional(number, 30)<br/>    retained_tag_prefixes = optional(list(string), ["v"])<br/>    read_access_arns      = optional(list(string), [])<br/><br/>    # Keys in `functions`: the permission on the repository's policy is what container Lambdas<br/>    # need, and without it the function's creation fails with an error that talks about an<br/>    # image not found.<br/>    lambda_read_access_functions = optional(list(string), [])<br/><br/>    tags = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_schedules"></a> [schedules](#input\_schedules) | EventBridge Scheduler schedules. The target references a function or a queue by key. | <pre>map(object({<br/>    description = optional(string)<br/>    expression  = string<br/>    timezone    = optional(string, "UTC")<br/>    enabled     = optional(bool, true)<br/>    group_name  = optional(string)<br/><br/>    target_function          = optional(string)<br/>    target_queue             = optional(string)<br/>    target_state_machine_arn = optional(string)<br/>    input                    = optional(string)<br/>    message_group_id         = optional(string)<br/><br/>    dead_letter_queue         = optional(string)<br/>    allow_missing_dead_letter = optional(bool, false)<br/><br/>    retry = optional(object({<br/>      maximum_retry_attempts       = optional(number, 3)<br/>      maximum_event_age_in_seconds = optional(number, 3600)<br/>    }), {})<br/><br/>    flexible_time_window_minutes = optional(number)<br/>    start_date                   = optional(string)<br/>    end_date                     = optional(string)<br/><br/>    tags = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_secrets"></a> [secrets](#input\_secrets) | Secrets in Secrets Manager. Created empty: the value is written by somebody else. | <pre>map(object({<br/>    description             = optional(string)<br/>    kms_key_id              = optional(string)<br/>    recovery_window_in_days = optional(number, 30)<br/>    initial_value           = optional(string)<br/>    ignore_value_changes    = optional(bool, true)<br/>    tags                    = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_security_groups"></a> [security\_groups](#input\_security\_groups) | Security groups. The functions reference them by key in `vpc.security_group_keys`. | <pre>map(object({<br/>    description = optional(string)<br/>    vpc_id      = optional(string)<br/>    vpc_name    = optional(string)<br/><br/>    ingress_cidr_rules = optional(list(object({<br/>      from_port   = number<br/>      to_port     = number<br/>      protocol    = optional(string, "tcp")<br/>      cidr_blocks = string<br/>      description = optional(string)<br/>    })), [])<br/><br/>    ingress_source_sg_rules = optional(list(object({<br/>      from_port                = number<br/>      to_port                  = number<br/>      protocol                 = optional(string, "tcp")<br/>      source_security_group_id = string<br/>      description              = optional(string)<br/>    })), [])<br/><br/>    ingress_self_rules = optional(list(object({<br/>      from_port   = number<br/>      to_port     = number<br/>      protocol    = optional(string, "tcp")<br/>      description = optional(string)<br/>    })), [])<br/><br/>    egress_cidr_rules = optional(list(object({<br/>      from_port   = number<br/>      to_port     = number<br/>      protocol    = optional(string, "tcp")<br/>      cidr_blocks = string<br/>      description = optional(string)<br/>    })), [])<br/><br/>    egress_source_sg_rules = optional(list(object({<br/>      from_port                = number<br/>      to_port                  = number<br/>      protocol                 = optional(string, "tcp")<br/>      source_security_group_id = string<br/>      description              = optional(string)<br/>    })), [])<br/><br/>    egress_self_rules = optional(list(object({<br/>      from_port   = number<br/>      to_port     = number<br/>      protocol    = optional(string, "tcp")<br/>      description = optional(string)<br/>    })), [])<br/><br/>    allow_all_egress = optional(bool, true)<br/>    tags             = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_sites"></a> [sites](#input\_sites) | Static sites: a private bucket plus CloudFront with Origin Access Control. | <pre>map(object({<br/>    comment                    = optional(string)<br/>    aliases                    = optional(list(string), [])<br/>    certificate_arn            = optional(string)<br/>    web_acl_arn                = optional(string)<br/>    zone_id                    = optional(string)<br/>    spa                        = optional(bool, false)<br/>    default_root_object        = optional(string, "index.html")<br/>    price_class                = optional(string, "PriceClass_100")<br/>    cache_policy_id            = optional(string, "658327ea-f89d-4fab-a63d-7e88639e58f6")<br/>    response_headers_policy_id = optional(string, "67f7725c-6f97-4210-82d7-5512b31e9d03")<br/>    allowed_methods            = optional(list(string), ["GET", "HEAD", "OPTIONS"])<br/>    bucket_force_destroy       = optional(bool, false)<br/>    wait_for_deployment        = optional(bool, false)<br/>    tags                       = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_tables"></a> [tables](#input\_tables) | DynamoDB tables. The key becomes the name's suffix and the reference used in `grants` and `env_from`. | <pre>map(object({<br/>    attributes = map(string)<br/>    hash_key   = string<br/>    range_key  = optional(string)<br/><br/>    billing_mode   = optional(string, "PAY_PER_REQUEST")<br/>    read_capacity  = optional(number)<br/>    write_capacity = optional(number)<br/>    table_class    = optional(string, "STANDARD")<br/><br/>    global_secondary_indexes = optional(map(object({<br/>      hash_key           = string<br/>      range_key          = optional(string)<br/>      projection_type    = optional(string, "ALL")<br/>      non_key_attributes = optional(list(string))<br/>      read_capacity      = optional(number)<br/>      write_capacity     = optional(number)<br/>    })), {})<br/><br/>    local_secondary_indexes = optional(map(object({<br/>      range_key          = string<br/>      projection_type    = optional(string, "ALL")<br/>      non_key_attributes = optional(list(string))<br/>    })), {})<br/><br/>    ttl = optional(object({<br/>      enabled        = optional(bool, false)<br/>      attribute_name = optional(string, "expires_at")<br/>    }), {})<br/><br/>    point_in_time_recovery = optional(object({<br/>      enabled        = optional(bool, true)<br/>      period_in_days = optional(number)<br/>    }), {})<br/><br/>    deletion_protection = optional(bool, true)<br/><br/>    stream = optional(object({<br/>      enabled   = optional(bool, false)<br/>      view_type = optional(string, "NEW_AND_OLD_IMAGES")<br/>    }), {})<br/><br/>    kms_key_arn = optional(string)<br/>    tags        = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource created. | `map(string)` | `{}` | no |
| <a name="input_topics"></a> [topics](#input\_topics) | SNS topics.<br/><br/>`to_queues` declares the fan-out towards the queues **from the topic side**, which is the<br/>natural form to read. The module inverts it and passes it to `modules/queue`, where fan-in<br/>from several topics can converge into a single policy document: SQS allows a single `Policy`<br/>attribute per queue, and this inversion is precisely the work that belongs to the<br/>composition.<br/><br/>    topics = {<br/>      operations = { to\_queues = { events = {} } }<br/>      audit      = { to\_queues = { events = { filter\_policy = jsonencode({ severity = ["critical"] }) } } }<br/>    } | <pre>map(object({<br/>    display_name = optional(string)<br/><br/>    fifo = optional(object({<br/>      enabled                     = optional(bool, false)<br/>      content_based_deduplication = optional(bool, false)<br/>      throughput_scope            = optional(string)<br/>    }), {})<br/><br/>    kms_key_id = optional(string)<br/><br/>    to_queues = optional(map(object({<br/>      filter_policy        = optional(string)<br/>      filter_policy_scope  = optional(string, "MessageAttributes")<br/>      raw_message_delivery = optional(bool, false)<br/>    })), {})<br/><br/>    subscriptions = optional(map(object({<br/>      protocol              = string<br/>      endpoint              = string<br/>      filter_policy         = optional(string)<br/>      filter_policy_scope   = optional(string, "MessageAttributes")<br/>      raw_message_delivery  = optional(bool)<br/>      subscription_role_arn = optional(string)<br/>    })), {})<br/><br/>    allow_publish_from = optional(list(object({<br/>      service        = string<br/>      source_arn     = optional(string)<br/>      source_account = optional(string)<br/>    })), [])<br/><br/>    tags = optional(map(string), {})<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alarm_arns"></a> [alarm\_arns](#output\_alarm\_arns) | All the ARNs of the alarms created by the primitives, for use in an external composite alarm. |
| <a name="output_alarm_topic_arn"></a> [alarm\_topic\_arn](#output\_alarm\_topic\_arn) | ARN of the alarm topic, wired automatically into every primitive. Null when observability is disabled. |
| <a name="output_buckets"></a> [buckets](#output\_buckets) | ARN and name of every bucket. |
| <a name="output_dashboard_name"></a> [dashboard\_name](#output\_dashboard\_name) | Name of the CloudWatch dashboard. Null when observability is disabled or there is nothing to show. |
| <a name="output_functions"></a> [functions](#output\_functions) | Name, ARN, log group and IAM decisions of every function, by key. |
| <a name="output_http_apis"></a> [http\_apis](#output\_http\_apis) | Endpoint, invocation URL and effective per-route authorization of every API. |
| <a name="output_queues"></a> [queues](#output\_queues) | ARN, name, URL and DLQ of every queue. |
| <a name="output_registries"></a> [registries](#output\_registries) | URL and name of every ECR repository. The URLs are the base of the container functions' `image`. |
| <a name="output_resources"></a> [resources](#output\_resources) | The resource registry exactly as it was passed to the functions.<br/><br/>It is there to extend the application with modules not covered by this composition: a<br/>function declared separately receives the same registry and the references resolve with the<br/>same keys. |
| <a name="output_schedules"></a> [schedules](#output\_schedules) | ARN, name and target type of every schedule. |
| <a name="output_secrets"></a> [secrets](#output\_secrets) | ARN and name of every secret, plus whether the value is managed by Terraform. |
| <a name="output_security_groups"></a> [security\_groups](#output\_security\_groups) | ID and VPC of every security group. |
| <a name="output_sites"></a> [sites](#output\_sites) | Distribution, domain name and bucket of every site. The bucket is the target of the syncs from CI. |
| <a name="output_tables"></a> [tables](#output\_tables) | ARN, name and stream ARN of every table. |
| <a name="output_topics"></a> [topics](#output\_topics) | ARN and name of every topic. |
| <a name="output_wiring"></a> [wiring](#output\_wiring) | The graph of resolved references, by key. It is the output to read in a review: it says<br/>what is connected to what without having to work it out from the configuration. |
<!-- END_TF_DOCS -->
