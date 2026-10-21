# glue-job

An AWS Glue job with its role, its log group, its network and the notification of its failed runs — on
the same principles as [`modules/function`](../function): the code comes from CI, the arguments reference
resources by key, the permissions are declared by intent.

## Usage

```hcl
module "reconcile" {
  source = "…//modules/glue-job"

  prefix = "acme-prod"
  name   = "reconcile"

  resources = module.app.resources

  script   = { bucket = "glue-scripts", key = "scripts/reconcile_etl_job.py" }
  temp_dir = { bucket = "glue-temp" }

  args = { "--ENV" = "prod" }
  args_from = {
    "--target_bucket" = { bucket = "documents" }
    "--SECRET_NAME"   = { secret = "database" }
    "--DYNAMO_TABLE"  = { table = "attributes" }
  }

  grants = {
    "bucket/documents" = ["read", "write"]
    "table/attributes" = ["read"]
    "secret/database"  = ["read"]
  }

  network = {
    subnet_id = "subnet-0abc"
    jdbc      = { url = "jdbc:postgresql://db.internal:5432/app", secret = "database" }
  }

  observability = {
    alarms = { actions = [module.app.alarm_topic_arn] }
  }
}
```

Inside [`modules/app`](../app) it is a `glue_jobs` entry, and the job enters the registry like any other
resource: a function starts it with `"glue_job/reconcile" = ["start"]` in `grants` and receives its name
with `{ glue_job = "reconcile" }` in `env_from`. A schedule starts it with `target_glue_job`.

## Why `glue-job` and not `job`

"Job" is Glue, AWS Batch on Fargate, an ECS task, EMR Serverless. Like the other primitives that map to
one service, the module is named after the service; and not `etl`, because Glue also runs Python shell
jobs that transform nothing, and an ETL can just as well be a Lambda.

## The code

The module **does not upload the script**: like a function's package, the code belongs to CI, which copies
it to the declared key. The bucket is a registry key, not a literal: a typo stops the plan.

The role gets `s3:GetObject` on the **script's object** and read/write on the **temp dir's prefix**, and
nothing else in those buckets. A `read` grant on the scripts bucket would let every job read every other
job's code; the temp dir defaults to `<job name>/` so that jobs sharing a bucket do not read each other's
leftovers. A CMK on either bucket adds the KMS permissions on its own, as `modules/grants` does.

## Arguments

`args` holds literal values, `args_from` references to registry resources — the same contract as a
function's `env` and `env_from`, with the same default attribute per type. The argument's name has no
effect on the resolution; a reference to a resource that does not exist stops the plan; the same argument
in both maps stops it too, rather than letting a `merge` pick one.

The module owns `--job-language`, `--TempDir` and the observability flags: they follow `temp_dir` and
`observability`, and setting them in `args` is an error. `default_arguments` in the outputs shows what the
script actually receives.

## IAM

| permission | where it comes from |
|---|---|
| Glue's own needs: the connection's ENIs, `/aws-glue/*` logs, metrics, catalog | `AWSGlueServiceRole`, always |
| the script, the temp dir | the module, narrowed to the object and the prefix |
| what the job does | `grants`, through [`modules/grants`](../grants) |
| anything else | `extra_policy_statements`, `managed_policy_arns` |

Whoever starts the job needs `start` on it, which is more than `StartJobRun`: `GetJobRun`, `GetJobRuns`
and `BatchStopJobRun` too, because a caller that starts a run and cannot ask how it ended is half a caller.

## Network

With `network` the module creates a Glue connection and a security group for the job, with the rule Glue
requires and nobody remembers: **inbound on every TCP port from the group itself**, which is how the
workers talk to each other. Without it the run fails at start. The database's security group then lets in
`security_group_id`, from the outputs.

The connection is `NETWORK` by default — a way into the VPC and nothing more — or `JDBC` with `jdbc`. A JDBC
connection holds the URL and the **name** of the secret with the credentials: no password reaches the
connection or the state. Glue reads the secret with the job's role, so `"secret/<key>" = ["read"]` must be in
`grants`, and the plan stops if it is not.

`connections` attaches existing connections by name, next to the module's: for a connection shared by
several jobs, whose network requirements belong to whoever owns it.

## Observability

Enabled by default, can be turned off flag by flag for a migration at parity of resources:

- **Log group** of the job's own, `/aws-glue/jobs/<job name>`, with a retention. Continuous logging writes
  there instead of Glue's shared groups, which have none and keep every run forever.
- **Metrics** and **job insights**, Glue's own flags.
- **Failure notification**: an EventBridge rule on the job's `Glue Job State Change` events in `FAILED`,
  `TIMEOUT` or `ERROR`, towards `alarms.actions` — typically the application's alarm topic. It is not a
  CloudWatch alarm because a failed run leaves nothing in alarm: the run ends, and without the rule the
  failure sits in a console tab nobody opens while the function that started the job has long returned.
  `STOPPED` is left out by default, because a stop is somebody's decision.

The topic's policy must let `events.amazonaws.com` publish: `modules/app` does it on the alarm topic when
there are jobs.

Continuous logging, metrics and insights are Spark features: a Python shell job gets none of them.

## Defaults that differ from Glue's

- **`timeout` is 60 minutes**, not 2880. A job that hangs is billed by the minute for two days before
  anybody is told; one that times out is a failure the notification reports.
- **`max_retries` is 0.** An ETL that is not idempotent must not run twice by accident.
- **Two `G.1X` workers**, the minimum Glue accepts, on the latest Glue version for Spark jobs.

## What it does not do

- Streaming jobs (`gluestreaming`): they run without an end, and the timeout, the retries and the failure
  notification do not apply to them.
- Triggers, workflows, crawlers, the Data Catalog: a job here is started by somebody — a function, a
  schedule — not by Glue's own orchestration.

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
| <a name="module_security_group"></a> [security\_group](#module\_security\_group) | ../security-group | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_event_rule.failed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.failed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_glue_connection.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_connection) | resource |
| [aws_glue_job.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/glue_job) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.grants](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.service](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_subnet.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | The job's name. If `prefix` is set the final name is `<prefix>-<name>`. | `string` | n/a | yes |
| <a name="input_script"></a> [script](#input\_script) | The job's script: a bucket of `resources.buckets`, by key, and the object's key.<br/><br/>    script = { bucket = "glue-scripts", key = "scripts/reconcile.py" }<br/><br/>The module does not upload the script: like a function's package, the code belongs<br/>to CI, which copies it to that key. What the module does is grant the job's role<br/>`s3:GetObject` on that one object — not a read on the whole bucket — so the job can<br/>always read its own script and nothing else in there without a grant of its own. | <pre>object({<br/>    bucket = string<br/>    key    = string<br/>  })</pre> | n/a | yes |
| <a name="input_args"></a> [args](#input\_args) | Job arguments with a literal value. The keys carry their leading `--`, as Glue wants<br/>them: `"--ENV" = "prod"`.<br/><br/>The arguments the module manages — `--job-language`, `--TempDir` and the<br/>observability flags — cannot be set here: they follow `temp_dir` and `observability`. | `map(string)` | `{}` | no |
| <a name="input_args_from"></a> [args\_from](#input\_args\_from) | Job arguments whose value is a reference to a resource in `resources`, resolved by<br/>the module — `env_from` for a job.<br/><br/>    args\_from = {<br/>      "--target\_bucket" = { bucket = "documents" }<br/>      "--SECRET\_NAME"   = { secret = "database" }<br/>      "--DYNAMO\_TABLE"  = { table  = "attributes" }<br/>    }<br/><br/>The default attribute per type is the one of `modules/function`'s `env_from`: `name`<br/>for buckets, tables, secrets and Glue jobs, `arn` for topics, `url` for queues. `attr`<br/>overrides it. A reference to a resource that does not exist makes the plan fail. | <pre>map(object({<br/>    bucket   = optional(string)<br/>    table    = optional(string)<br/>    topic    = optional(string)<br/>    queue    = optional(string)<br/>    secret   = optional(string)<br/>    glue_job = optional(string)<br/>    attr     = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_command"></a> [command](#input\_command) | The kind of job: `glueetl` (Spark) or `pythonshell`.<br/><br/>Streaming jobs (`gluestreaming`) are not covered: they run without an end, and the<br/>timeout, the retries and the failure notification this module is built around do not<br/>apply to them. | `string` | `"glueetl"` | no |
| <a name="input_connections"></a> [connections](#input\_connections) | Names of existing Glue connections to attach, in addition to the one `network`<br/>creates. For connections owned elsewhere — one shared by several jobs, typically —<br/>whose security group requirements are that owner's business. | `list(string)` | `[]` | no |
| <a name="input_description"></a> [description](#input\_description) | The job's description. | `string` | `null` | no |
| <a name="input_execution_class"></a> [execution\_class](#input\_execution\_class) | `STANDARD` or `FLEX`. Null leaves Glue's default, `STANDARD`. | `string` | `null` | no |
| <a name="input_extra_policy_statements"></a> [extra\_policy\_statements](#input\_extra\_policy\_statements) | Literal IAM statements, for services outside the capability table. | <pre>list(object({<br/>    sid       = optional(string)<br/>    effect    = optional(string, "Allow")<br/>    actions   = list(string)<br/>    resources = list(string)<br/>    condition = optional(list(object({<br/>      test     = string<br/>      variable = string<br/>      values   = list(string)<br/>    })), [])<br/>  }))</pre> | `[]` | no |
| <a name="input_glue_version"></a> [glue\_version](#input\_glue\_version) | Glue version. Null picks `5.0` for `glueetl` and `3.0` for `pythonshell`. | `string` | `null` | no |
| <a name="input_grants"></a> [grants](#input\_grants) | Permissions declared by intent, in the form `<type>/<name> = [capability]`. They are<br/>translated into policies by `modules/grants`, which documents the table.<br/><br/>    grants = {<br/>      "bucket/documents" = ["read", "write"]<br/>      "table/attributes" = ["read"]<br/>      "secret/database"  = ["read"]<br/>    }<br/><br/>The script and the temp dir need no grant: the module gives the role exactly the<br/>access they require. | `map(list(string))` | `{}` | no |
| <a name="input_managed_policy_arns"></a> [managed\_policy\_arns](#input\_managed\_policy\_arns) | ARNs of managed policies to attach to the role, in addition to `AWSGlueServiceRole`. An escape hatch: prefer `grants`. | `list(string)` | `[]` | no |
| <a name="input_max_capacity"></a> [max\_capacity](#input\_max\_capacity) | `pythonshell` only: the DPUs, `0.0625` or `1`. Null picks `0.0625`. | `number` | `null` | no |
| <a name="input_max_concurrent_runs"></a> [max\_concurrent\_runs](#input\_max\_concurrent\_runs) | How many runs of the job may be in progress at once. A StartJobRun beyond it is refused with ConcurrentRunsExceededException. | `number` | `1` | no |
| <a name="input_max_retries"></a> [max\_retries](#input\_max\_retries) | How many times Glue retries a failed run. 0 by default: an ETL that is not idempotent must not run twice by accident. | `number` | `0` | no |
| <a name="input_network"></a> [network](#input\_network) | Runs the job inside a VPC, through a Glue connection the module creates.<br/><br/>    network = {<br/>      subnet\_id = "subnet-0abc"<br/>      jdbc      = { url = "jdbc:postgresql://db.internal:5432/app", secret = "database" }<br/>    }<br/><br/>The module creates a security group for the job with the rule Glue requires and<br/>nobody remembers: inbound on every TCP port **from the group itself**, which is how<br/>the workers talk to each other. Without it the run fails at start with a message<br/>about the connection. The database's own group then lets this one in:<br/>`security_group_id` is in the outputs.<br/><br/>Without `jdbc` the connection is of type `NETWORK`, which gives the job a way into<br/>the VPC and nothing else. With `jdbc` it is of type `JDBC`: `secret` is a key of<br/>`resources.secrets` holding the credentials, and the job's grants must include<br/>`"secret/<key>" = ["read"]`, because Glue reads it with the job's role.<br/><br/>The availability zone is read from the subnet. `security_group_ids` are added to the<br/>module's group, not substituted for it. | <pre>object({<br/>    subnet_id          = string<br/>    security_group_ids = optional(list(string), [])<br/>    jdbc = optional(object({<br/>      url    = string<br/>      secret = string<br/>    }))<br/>  })</pre> | `null` | no |
| <a name="input_number_of_workers"></a> [number\_of\_workers](#input\_number\_of\_workers) | `glueetl` only: the number of workers, driver included. Null picks 2, the minimum Glue accepts. | `number` | `null` | no |
| <a name="input_observability"></a> [observability](#input\_observability) | Logs, metrics and the failure notification. Enabled by default and can be turned<br/>off, flag by flag, for a migration at parity of resources.<br/><br/>`continuous_logging`, `metrics` and `job_insights` apply to `glueetl` only: a Python<br/>shell job writes to Glue's shared log groups and has none of the three. The log<br/>group is the job's own, `/aws-glue/jobs/<job name>`, with a retention: Glue's shared<br/>groups have none and keep every run forever.<br/><br/>`alarms` is not a CloudWatch alarm: a run that fails ends, and there is no metric<br/>that stays in alarm. It is an EventBridge rule on the job's state changes towards<br/>`actions` — SNS topics, typically the application's alarm topic, whose policy must<br/>let `events.amazonaws.com` publish. `states` are the run states that notify;<br/>`STOPPED` is not among them by default, because a stop is somebody's decision. | <pre>object({<br/>    log_retention_days = optional(number, 7)<br/>    log_kms_key_id     = optional(string)<br/>    continuous_logging = optional(bool, true)<br/>    metrics            = optional(bool, true)<br/>    job_insights       = optional(bool, true)<br/>    alarms = optional(object({<br/>      enabled = optional(bool, true)<br/>      actions = optional(list(string), [])<br/>      states  = optional(list(string), ["FAILED", "TIMEOUT", "ERROR"])<br/>    }), {})<br/>  })</pre> | `{}` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, typically `<project>-<environment>`. Left null, `name` is used as is. | `string` | `null` | no |
| <a name="input_python_version"></a> [python\_version](#input\_python\_version) | Python version. Null picks `3` for `glueetl` and `3.9` for `pythonshell`. | `string` | `null` | no |
| <a name="input_resources"></a> [resources](#input\_resources) | The registry of resources referenceable from `script`, `temp_dir`, `args_from`,<br/>`grants` and `network.jdbc`. The same shape `modules/grants` and `modules/function`<br/>accept: build it once and pass it to all of them. | <pre>object({<br/>    buckets = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    tables = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    topics = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    queues = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    secrets = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>    glue_jobs = optional(map(object({<br/>      arn         = string<br/>      name        = optional(string)<br/>      url         = optional(string)<br/>      kms_key_arn = optional(string)<br/>    })), {})<br/>  })</pre> | `{}` | no |
| <a name="input_role_name"></a> [role\_name](#input\_role\_name) | Name of the job's role. Derived from the job's name when null: `<job name>-glue`,<br/>shortened with a hash past the 64 characters IAM allows. | `string` | `null` | no |
| <a name="input_security_configuration"></a> [security\_configuration](#input\_security\_configuration) | The name of an existing Glue security configuration, for encryption at rest of what the job writes to S3, CloudWatch and its bookmarks. | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |
| <a name="input_temp_dir"></a> [temp\_dir](#input\_temp\_dir) | Glue's working directory, `--TempDir`: a bucket of `resources.buckets`, by key, and a<br/>prefix. Null leaves the job without one.<br/><br/>The prefix defaults to `<job name>/`, so that several jobs can share one bucket<br/>without reading each other's leftovers. The role receives read and write on that<br/>prefix only. | <pre>object({<br/>    bucket = string<br/>    prefix = optional(string)<br/>  })</pre> | `null` | no |
| <a name="input_timeout"></a> [timeout](#input\_timeout) | Timeout in minutes. 60 by default and not Glue's own 2880: a job that hangs is billed<br/>by the minute for two days before anybody is told, while one that times out is a<br/>failure the failure notification reports. | `number` | `60` | no |
| <a name="input_worker_type"></a> [worker\_type](#input\_worker\_type) | `glueetl` only: the worker type. Null picks `G.1X`. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_arn"></a> [arn](#output\_arn) | The job's ARN. |
| <a name="output_connection_name"></a> [connection\_name](#output\_connection\_name) | The Glue connection the module created. Null without `network`. |
| <a name="output_default_arguments"></a> [default\_arguments](#output\_default\_arguments) | The job's effective arguments, with the references resolved and the managed ones included. Useful in tests and to know what the script receives. |
| <a name="output_failure_rule_arn"></a> [failure\_rule\_arn](#output\_failure\_rule\_arn) | The EventBridge rule notifying failed runs. Null when the notification is off. |
| <a name="output_iam"></a> [iam](#output\_iam) | Which permissions the module decided to give the role, beyond `AWSGlueServiceRole`,<br/>from the job's actual configuration. Inspectable without reading the state. |
| <a name="output_log_group_name"></a> [log\_group\_name](#output\_log\_group\_name) | The job's own log group, where continuous logging writes. Null for a Python shell job or with continuous logging off. |
| <a name="output_name"></a> [name](#output\_name) | The job's name, already prefixed. It is what StartJobRun takes. |
| <a name="output_policy_json"></a> [policy\_json](#output\_policy\_json) | The inline policy of the role: grants, script, temp dir and extra statements. For inspection and tests. |
| <a name="output_registry_entry"></a> [registry\_entry](#output\_registry\_entry) | The entry for `resources.glue_jobs`, in the shape the registry expects, so that a<br/>function can be granted `"glue_job/<key>" = ["start"]` and receive the name through<br/>`env_from`. |
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | The job's role ARN. |
| <a name="output_role_name"></a> [role\_name](#output\_role\_name) | The job's role name, to attach policies from the outside. |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | The job's security group. Null without `network`. It is the source to let in on the<br/>database's security group: the job reaches the database from here. |
<!-- END_TF_DOCS -->
