variable "name" {
  description = "The job's name. If `prefix` is set the final name is `<prefix>-<name>`."
  type        = string
}

variable "prefix" {
  description = "Naming prefix, typically `<project>-<environment>`. Left null, `name` is used as is."
  type        = string
  default     = null
}

variable "description" {
  description = "The job's description."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# Code
# ------------------------------------------------------------------------------

variable "script" {
  description = <<-EOT
    The job's script: a bucket of `resources.buckets`, by key, and the object's key.

        script = { bucket = "glue-scripts", key = "scripts/reconcile.py" }

    The module does not upload the script: like a function's package, the code belongs
    to CI, which copies it to that key. What the module does is grant the job's role
    `s3:GetObject` on that one object — not a read on the whole bucket — so the job can
    always read its own script and nothing else in there without a grant of its own.
  EOT
  type = object({
    bucket = string
    key    = string
  })

  validation {
    condition     = var.script.key != "" && !startswith(var.script.key, "/")
    error_message = "script.key is an object key, relative to the bucket: `scripts/job.py`, not `/scripts/job.py`."
  }

  validation {
    condition     = contains(keys(var.resources.buckets), var.script.bucket)
    error_message = format("script.bucket references the bucket '%s', which is not in `resources.buckets`. Available: %s.", var.script.bucket, join(", ", keys(var.resources.buckets)))
  }
}

variable "temp_dir" {
  description = <<-EOT
    Glue's working directory, `--TempDir`: a bucket of `resources.buckets`, by key, and a
    prefix. Null leaves the job without one.

    The prefix defaults to `<job name>/`, so that several jobs can share one bucket
    without reading each other's leftovers. The role receives read and write on that
    prefix only.
  EOT
  type = object({
    bucket = string
    prefix = optional(string)
  })
  default = null

  validation {
    condition     = var.temp_dir == null || contains(keys(var.resources.buckets), try(var.temp_dir.bucket, ""))
    error_message = format("temp_dir.bucket references a bucket that is not in `resources.buckets`. Available: %s.", join(", ", keys(var.resources.buckets)))
  }

  validation {
    condition     = try(var.temp_dir.prefix, null) == null || !startswith(coalesce(try(var.temp_dir.prefix, null), "x"), "/")
    error_message = "temp_dir.prefix is relative to the bucket: `temp/`, not `/temp/`."
  }
}

# ------------------------------------------------------------------------------
# Runtime and capacity
# ------------------------------------------------------------------------------

variable "command" {
  description = <<-EOT
    The kind of job: `glueetl` (Spark) or `pythonshell`.

    Streaming jobs (`gluestreaming`) are not covered: they run without an end, and the
    timeout, the retries and the failure notification this module is built around do not
    apply to them.
  EOT
  type        = string
  default     = "glueetl"

  validation {
    condition     = contains(["glueetl", "pythonshell"], var.command)
    error_message = "command must be 'glueetl' or 'pythonshell'."
  }
}

variable "glue_version" {
  description = "Glue version. Null picks `5.0` for `glueetl` and `3.0` for `pythonshell`."
  type        = string
  default     = null
}

variable "python_version" {
  description = "Python version. Null picks `3` for `glueetl` and `3.9` for `pythonshell`."
  type        = string
  default     = null
}

variable "worker_type" {
  description = "`glueetl` only: the worker type. Null picks `G.1X`."
  type        = string
  default     = null

  # Glue rejects workers on a Python shell job at apply, after the plan was approved.
  validation {
    condition     = var.worker_type == null || var.command == "glueetl"
    error_message = "worker_type applies to `glueetl` jobs only: a Python shell job is sized with `max_capacity`."
  }
}

variable "number_of_workers" {
  description = "`glueetl` only: the number of workers, driver included. Null picks 2, the minimum Glue accepts."
  type        = number
  default     = null

  validation {
    condition     = var.number_of_workers == null || try(var.number_of_workers >= 2, false)
    error_message = "number_of_workers must be at least 2: one of them is the driver."
  }

  validation {
    condition     = var.number_of_workers == null || var.command == "glueetl"
    error_message = "number_of_workers applies to `glueetl` jobs only: a Python shell job is sized with `max_capacity`."
  }
}

variable "max_capacity" {
  description = "`pythonshell` only: the DPUs, `0.0625` or `1`. Null picks `0.0625`."
  type        = number
  default     = null

  validation {
    condition     = var.max_capacity == null || contains([0.0625, 1], coalesce(var.max_capacity, 0))
    error_message = "max_capacity must be 0.0625 or 1."
  }

  validation {
    condition     = var.max_capacity == null || var.command == "pythonshell"
    error_message = "max_capacity applies to `pythonshell` jobs only: a Spark job is sized with `worker_type` and `number_of_workers`."
  }
}

variable "timeout" {
  description = <<-EOT
    Timeout in minutes. 60 by default and not Glue's own 2880: a job that hangs is billed
    by the minute for two days before anybody is told, while one that times out is a
    failure the failure notification reports.
  EOT
  type        = number
  default     = 60

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 10080
    error_message = "timeout must be between 1 and 10080 minutes."
  }
}

variable "max_retries" {
  description = "How many times Glue retries a failed run. 0 by default: an ETL that is not idempotent must not run twice by accident."
  type        = number
  default     = 0

  validation {
    condition     = var.max_retries >= 0 && var.max_retries <= 10
    error_message = "max_retries must be between 0 and 10."
  }
}

variable "max_concurrent_runs" {
  description = "How many runs of the job may be in progress at once. A StartJobRun beyond it is refused with ConcurrentRunsExceededException."
  type        = number
  default     = 1

  validation {
    condition     = var.max_concurrent_runs >= 1
    error_message = "max_concurrent_runs must be at least 1."
  }
}

variable "execution_class" {
  description = "`STANDARD` or `FLEX`. Null leaves Glue's default, `STANDARD`."
  type        = string
  default     = null

  validation {
    condition     = var.execution_class == null || contains(["STANDARD", "FLEX"], coalesce(var.execution_class, "x"))
    error_message = "execution_class must be 'STANDARD' or 'FLEX'."
  }
}

variable "security_configuration" {
  description = "The name of an existing Glue security configuration, for encryption at rest of what the job writes to S3, CloudWatch and its bookmarks."
  type        = string
  default     = null
}

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------

variable "network" {
  description = <<-EOT
    Runs the job inside a VPC, through a Glue connection the module creates.

        network = {
          subnet_id = "subnet-0abc"
          jdbc      = { url = "jdbc:postgresql://db.internal:5432/app", secret = "database" }
        }

    The module creates a security group for the job with the rule Glue requires and
    nobody remembers: inbound on every TCP port **from the group itself**, which is how
    the workers talk to each other. Without it the run fails at start with a message
    about the connection. The database's own group then lets this one in:
    `security_group_id` is in the outputs.

    Without `jdbc` the connection is of type `NETWORK`, which gives the job a way into
    the VPC and nothing else. With `jdbc` it is of type `JDBC`: `secret` is a key of
    `resources.secrets` holding the credentials, and the job's grants must include
    `"secret/<key>" = ["read"]`, because Glue reads it with the job's role.

    The availability zone is read from the subnet. `security_group_ids` are added to the
    module's group, not substituted for it.
  EOT
  type = object({
    subnet_id          = string
    security_group_ids = optional(list(string), [])
    jdbc = optional(object({
      url    = string
      secret = string
    }))
  })
  default = null

  validation {
    condition     = try(var.network.jdbc, null) == null || contains(keys(var.resources.secrets), try(var.network.jdbc.secret, ""))
    error_message = format("network.jdbc.secret references a secret that is not in `resources.secrets`. Available: %s.", join(", ", keys(var.resources.secrets)))
  }

  # The connection exists, the secret exists, and the run fails at start with an
  # AccessDenied on Secrets Manager. The two sides are declared in different places, so
  # their coherence is checked here and not discovered at runtime.
  validation {
    condition = try(var.network.jdbc, null) == null || contains(
      try(var.grants[format("secret/%s", var.network.jdbc.secret)], []), "read"
    )
    error_message = "network.jdbc.secret is read by Glue with the job's role: add `\"secret/<key>\" = [\"read\"]` to grants."
  }
}

variable "connections" {
  description = <<-EOT
    Names of existing Glue connections to attach, in addition to the one `network`
    creates. For connections owned elsewhere — one shared by several jobs, typically —
    whose security group requirements are that owner's business.
  EOT
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------------------------
# Configuration and references
# ------------------------------------------------------------------------------

variable "args" {
  description = <<-EOT
    Job arguments with a literal value. The keys carry their leading `--`, as Glue wants
    them: `"--ENV" = "prod"`.

    The arguments the module manages — `--job-language`, `--TempDir` and the
    observability flags — cannot be set here: they follow `temp_dir` and `observability`.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.args) : startswith(k, "--")])
    error_message = format("Glue job arguments start with `--`. Non-conforming: %s.", join(", ", [for k in keys(var.args) : k if !startswith(k, "--")]))
  }

  validation {
    condition = length(setintersection(keys(var.args), [
      "--job-language", "--TempDir", "--enable-metrics", "--enable-continuous-cloudwatch-log", "--continuous-log-logGroup", "--enable-job-insights",
    ])) == 0
    error_message = "args sets an argument the module manages — `--job-language`, `--TempDir`, `--enable-metrics`, `--enable-continuous-cloudwatch-log`, `--continuous-log-logGroup`, `--enable-job-insights`. Use `temp_dir` and `observability` instead."
  }
}

variable "args_from" {
  description = <<-EOT
    Job arguments whose value is a reference to a resource in `resources`, resolved by
    the module — `env_from` for a job.

        args_from = {
          "--target_bucket" = { bucket = "documents" }
          "--SECRET_NAME"   = { secret = "database" }
          "--DYNAMO_TABLE"  = { table  = "attributes" }
        }

    The default attribute per type is the one of `modules/function`'s `env_from`: `name`
    for buckets, tables, secrets and Glue jobs, `arn` for topics, `url` for queues. `attr`
    overrides it. A reference to a resource that does not exist makes the plan fail.
  EOT
  type = map(object({
    bucket   = optional(string)
    table    = optional(string)
    topic    = optional(string)
    queue    = optional(string)
    secret   = optional(string)
    glue_job = optional(string)
    attr     = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.args_from) : startswith(k, "--")])
    error_message = format("Glue job arguments start with `--`. Non-conforming: %s.", join(", ", [for k in keys(var.args_from) : k if !startswith(k, "--")]))
  }

  validation {
    condition = alltrue([
      for k, r in var.args_from :
      length([for v in [r.bucket, r.table, r.topic, r.queue, r.secret, r.glue_job] : v if v != null]) == 1
    ])
    error_message = format(
      "Every args_from entry must state exactly one resource type among bucket, table, topic, queue, secret, glue_job. Non-conforming entries: %s.",
      join(", ", [
        for k, r in var.args_from : k
        if length([for v in [r.bucket, r.table, r.topic, r.queue, r.secret, r.glue_job] : v if v != null]) != 1
      ])
    )
  }

  validation {
    condition = alltrue([
      for r in values(var.args_from) : r.attr == null || contains(["name", "arn", "url"], r.attr)
    ])
    error_message = "attr must be 'name', 'arn' or 'url'."
  }

  validation {
    condition = alltrue([
      for r in values(var.args_from) :
      (r.bucket == null || contains(keys(var.resources.buckets), coalesce(r.bucket, ""))) &&
      (r.table == null || contains(keys(var.resources.tables), coalesce(r.table, ""))) &&
      (r.topic == null || contains(keys(var.resources.topics), coalesce(r.topic, ""))) &&
      (r.queue == null || contains(keys(var.resources.queues), coalesce(r.queue, ""))) &&
      (r.secret == null || contains(keys(var.resources.secrets), coalesce(r.secret, ""))) &&
      (r.glue_job == null || contains(keys(var.resources.glue_jobs), coalesce(r.glue_job, "")))
    ])
    error_message = format(
      "args_from references resources that are not in `resources`: %s. Available registry: buckets [%s], tables [%s], topics [%s], queues [%s], secrets [%s], glue_jobs [%s].",
      join(", ", [
        for k, r in var.args_from : format("%s → %s", k, coalesce(r.bucket, r.table, r.topic, r.queue, r.secret, r.glue_job, "?"))
        if !(
          (r.bucket == null || contains(keys(var.resources.buckets), coalesce(r.bucket, ""))) &&
          (r.table == null || contains(keys(var.resources.tables), coalesce(r.table, ""))) &&
          (r.topic == null || contains(keys(var.resources.topics), coalesce(r.topic, ""))) &&
          (r.queue == null || contains(keys(var.resources.queues), coalesce(r.queue, ""))) &&
          (r.secret == null || contains(keys(var.resources.secrets), coalesce(r.secret, ""))) &&
          (r.glue_job == null || contains(keys(var.resources.glue_jobs), coalesce(r.glue_job, "")))
        )
      ]),
      join(", ", keys(var.resources.buckets)),
      join(", ", keys(var.resources.tables)),
      join(", ", keys(var.resources.topics)),
      join(", ", keys(var.resources.queues)),
      join(", ", keys(var.resources.secrets)),
      join(", ", keys(var.resources.glue_jobs)),
    )
  }

  # The same argument in both maps would be resolved in one of the two directions in
  # silence, and which one would depend on the order of a `merge`.
  validation {
    condition     = length(setintersection(keys(var.args), keys(var.args_from))) == 0
    error_message = format("Arguments declared in both args and args_from: %s.", join(", ", setintersection(keys(var.args), keys(var.args_from))))
  }

  validation {
    condition = length(setintersection(keys(var.args_from), [
      "--job-language", "--TempDir", "--enable-metrics", "--enable-continuous-cloudwatch-log", "--continuous-log-logGroup", "--enable-job-insights",
    ])) == 0
    error_message = "args_from sets an argument the module manages. Use `temp_dir` and `observability` instead."
  }
}

variable "resources" {
  description = <<-EOT
    The registry of resources referenceable from `script`, `temp_dir`, `args_from`,
    `grants` and `network.jdbc`. The same shape `modules/grants` and `modules/function`
    accept: build it once and pass it to all of them.
  EOT
  type = object({
    buckets = optional(map(object({
      arn         = string
      name        = optional(string)
      url         = optional(string)
      kms_key_arn = optional(string)
    })), {})
    tables = optional(map(object({
      arn         = string
      name        = optional(string)
      url         = optional(string)
      kms_key_arn = optional(string)
    })), {})
    topics = optional(map(object({
      arn         = string
      name        = optional(string)
      url         = optional(string)
      kms_key_arn = optional(string)
    })), {})
    queues = optional(map(object({
      arn         = string
      name        = optional(string)
      url         = optional(string)
      kms_key_arn = optional(string)
    })), {})
    secrets = optional(map(object({
      arn         = string
      name        = optional(string)
      url         = optional(string)
      kms_key_arn = optional(string)
    })), {})
    glue_jobs = optional(map(object({
      arn         = string
      name        = optional(string)
      url         = optional(string)
      kms_key_arn = optional(string)
    })), {})
  })
  default = {}
}

# ------------------------------------------------------------------------------
# IAM
# ------------------------------------------------------------------------------

variable "role_name" {
  description = <<-EOT
    Name of the job's role. Derived from the job's name when null: `<job name>-glue`,
    shortened with a hash past the 64 characters IAM allows.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.role_name == null || length(coalesce(var.role_name, "")) <= 64
    error_message = "An IAM role name stops at 64 characters."
  }
}

variable "grants" {
  description = <<-EOT
    Permissions declared by intent, in the form `<type>/<name> = [capability]`. They are
    translated into policies by `modules/grants`, which documents the table.

        grants = {
          "bucket/documents" = ["read", "write"]
          "table/attributes" = ["read"]
          "secret/database"  = ["read"]
        }

    The script and the temp dir need no grant: the module gives the role exactly the
    access they require.
  EOT
  type        = map(list(string))
  default     = {}
}

variable "extra_policy_statements" {
  description = "Literal IAM statements, for services outside the capability table."
  type = list(object({
    sid       = optional(string)
    effect    = optional(string, "Allow")
    actions   = list(string)
    resources = list(string)
    condition = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
  }))
  default = []
}

variable "managed_policy_arns" {
  description = "ARNs of managed policies to attach to the role, in addition to `AWSGlueServiceRole`. An escape hatch: prefer `grants`."
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------------------------
# Observability
# ------------------------------------------------------------------------------

variable "observability" {
  description = <<-EOT
    Logs, metrics and the failure notification. Enabled by default and can be turned
    off, flag by flag, for a migration at parity of resources.

    `continuous_logging`, `metrics` and `job_insights` apply to `glueetl` only: a Python
    shell job writes to Glue's shared log groups and has none of the three. The log
    group is the job's own, `/aws-glue/jobs/<job name>`, with a retention: Glue's shared
    groups have none and keep every run forever.

    `alarms` is not a CloudWatch alarm: a run that fails ends, and there is no metric
    that stays in alarm. It is an EventBridge rule on the job's state changes towards
    `actions` — SNS topics, typically the application's alarm topic, whose policy must
    let `events.amazonaws.com` publish. `states` are the run states that notify;
    `STOPPED` is not among them by default, because a stop is somebody's decision.
  EOT
  type = object({
    log_retention_days = optional(number, 7)
    log_kms_key_id     = optional(string)
    continuous_logging = optional(bool, true)
    metrics            = optional(bool, true)
    job_insights       = optional(bool, true)
    alarms = optional(object({
      enabled = optional(bool, true)
      actions = optional(list(string), [])
      states  = optional(list(string), ["FAILED", "TIMEOUT", "ERROR"])
    }), {})
  })
  default = {}

  validation {
    condition = alltrue([
      for s in var.observability.alarms.states : contains(["FAILED", "TIMEOUT", "ERROR", "STOPPED", "SUCCEEDED"], s)
    ])
    error_message = "observability.alarms.states accepts FAILED, TIMEOUT, ERROR, STOPPED, SUCCEEDED."
  }

  validation {
    condition     = length(var.observability.alarms.states) > 0
    error_message = "observability.alarms.states cannot be empty: to notify nothing, set `enabled = false`."
  }
}
