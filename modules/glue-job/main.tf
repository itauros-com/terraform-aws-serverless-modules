data "aws_partition" "current" {}

locals {
  job_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.job_name })

  is_spark = var.command == "glueetl"

  glue_version   = var.glue_version != null ? var.glue_version : (local.is_spark ? "5.0" : "3.0")
  python_version = var.python_version != null ? var.python_version : (local.is_spark ? "3" : "3.9")

  # IAM role names stop at 64 characters. Shortened deterministically, as in
  # modules/schedule: 55 characters, then 8 hex of the full name's hash. Plain truncation
  # would collide between two jobs sharing a long prefix.
  role_base = format("%s-glue", local.job_name)
  role_name = var.role_name != null ? var.role_name : (
    length(local.role_base) <= 64 ? local.role_base : format(
      "%s-%s", substr(local.role_base, 0, 55), substr(sha1(local.role_base), 0, 8)
    )
  )

  # ----------------------------------------------------------------------------
  # Script and temp dir
  #
  # Both are buckets of the registry, by key. The access the job needs on them is
  # granted here, narrower than any capability: `read` on the scripts bucket would let
  # every job read every other job's code.
  # ----------------------------------------------------------------------------
  script_bucket   = var.resources.buckets[var.script.bucket]
  script_location = format("s3://%s/%s", coalesce(local.script_bucket.name, "?"), var.script.key)

  temp_bucket = var.temp_dir == null ? null : var.resources.buckets[var.temp_dir.bucket]
  temp_prefix = var.temp_dir == null ? null : coalesce(var.temp_dir.prefix, format("%s/", local.job_name))
  temp_dir    = var.temp_dir == null ? null : format("s3://%s/%s", coalesce(local.temp_bucket.name, "?"), local.temp_prefix)

  code_statements = concat(
    [
      {
        sid       = "ReadScript"
        effect    = "Allow"
        actions   = ["s3:GetObject"]
        resources = [format("%s/%s", local.script_bucket.arn, var.script.key)]
        condition = []
      },
    ],
    var.temp_dir == null ? [] : [
      {
        sid       = "ListTempDir"
        effect    = "Allow"
        actions   = ["s3:ListBucket"]
        resources = [local.temp_bucket.arn]
        condition = [{ test = "StringLike", variable = "s3:prefix", values = [format("%s*", local.temp_prefix)] }]
      },
      {
        sid       = "UseTempDir"
        effect    = "Allow"
        actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        resources = [format("%s/%s*", local.temp_bucket.arn, local.temp_prefix)]
        condition = []
      },
    ],
    # The same implicit KMS permissions `modules/grants` adds for a CMK: without them the
    # policy on S3 is right and the job fails on an AccessDenied from KMS.
    try(local.script_bucket.kms_key_arn, null) == null ? [] : [
      {
        sid       = "DecryptScript"
        effect    = "Allow"
        actions   = ["kms:Decrypt"]
        resources = [local.script_bucket.kms_key_arn]
        condition = []
      },
    ],
    try(local.temp_bucket.kms_key_arn, null) == null ? [] : [
      {
        sid       = "EncryptTempDir"
        effect    = "Allow"
        actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
        resources = [local.temp_bucket.kms_key_arn]
        condition = []
      },
    ],
  )

  # ----------------------------------------------------------------------------
  # Arguments
  # ----------------------------------------------------------------------------
  registry = {
    buckets   = var.resources.buckets
    tables    = var.resources.tables
    topics    = var.resources.topics
    queues    = var.resources.queues
    secrets   = var.resources.secrets
    glue_jobs = var.resources.glue_jobs
  }

  # The same table as `env_from` in modules/function: a reference means the same thing
  # whether it ends up in an environment variable or in a job argument.
  args_from_types = {
    bucket   = { registry = "buckets", default_attr = "name" }
    table    = { registry = "tables", default_attr = "name" }
    topic    = { registry = "topics", default_attr = "arn" }
    queue    = { registry = "queues", default_attr = "url" }
    secret   = { registry = "secrets", default_attr = "name" }
    glue_job = { registry = "glue_jobs", default_attr = "name" }
  }

  args_from_parsed = {
    for k, r in var.args_from : k => {
      type = (
        r.bucket != null ? "bucket" :
        r.table != null ? "table" :
        r.topic != null ? "topic" :
        r.queue != null ? "queue" :
        r.secret != null ? "secret" :
        r.glue_job != null ? "glue_job" :
        null
      )
      name = coalesce(r.bucket, r.table, r.topic, r.queue, r.secret, r.glue_job, "")
      attr = r.attr
    }
  }

  # The `try` routes the error to the precondition on `arn`, which names the argument
  # and the resource. The resource's existence is checked by `args_from`'s validations:
  # what is caught here is a resource that does not expose the requested attribute.
  args_from_resolved = {
    for k, p in local.args_from_parsed : k => try(
      local.registry[local.args_from_types[p.type].registry][p.name][coalesce(p.attr, local.args_from_types[p.type].default_attr)],
      null
    )
  }

  args_from_unresolved = sort([
    for k, v in local.args_from_resolved : format(
      "%s → %s/%s.%s",
      k,
      local.args_from_parsed[k].type,
      local.args_from_parsed[k].name,
      coalesce(local.args_from_parsed[k].attr, local.args_from_types[local.args_from_parsed[k].type].default_attr),
    ) if v == null
  ])

  log_group_name = format("/aws-glue/jobs/%s", local.job_name)
  has_log_group  = local.is_spark && var.observability.continuous_logging

  # The arguments the module owns. `args` and `args_from` cannot set them: their
  # validations stop the plan, rather than letting a `merge` decide in silence.
  managed_args = merge(
    { "--job-language" = "python" },
    var.temp_dir == null ? {} : { "--TempDir" = local.temp_dir },
    local.is_spark && var.observability.metrics ? { "--enable-metrics" = "true" } : {},
    local.has_log_group ? {
      "--enable-continuous-cloudwatch-log" = "true"
      "--continuous-log-logGroup"          = local.log_group_name
    } : {},
    local.is_spark && var.observability.job_insights ? { "--enable-job-insights" = "true" } : {},
  )

  default_arguments = merge(
    local.managed_args,
    var.args,
    { for k, v in local.args_from_resolved : k => v if v != null },
  )

  # ----------------------------------------------------------------------------
  # Network
  # ----------------------------------------------------------------------------
  has_network = var.network != null
  has_jdbc    = try(var.network.jdbc, null) != null

  connection_names = concat(
    local.has_network ? [aws_glue_connection.this[0].name] : [],
    var.connections,
  )
}

module "grants" {
  source = "../grants"

  resources        = var.resources
  grants           = var.grants
  extra_statements = concat(local.code_statements, var.extra_policy_statements)
}

# ------------------------------------------------------------------------------
# Role
# ------------------------------------------------------------------------------

resource "aws_iam_role" "this" {
  name        = local.role_name
  description = format("Glue job %s", local.job_name)
  tags        = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

# What Glue itself needs to run the job, independent of what the job does: the network
# interfaces of a connection, the `/aws-glue/*` log groups, the metrics, the catalog. It
# is AWS's own policy, kept current by AWS as Glue changes.
resource "aws_iam_role_policy_attachment" "service" {
  role       = aws_iam_role.this.name
  policy_arn = format("arn:%s:iam::aws:policy/service-role/AWSGlueServiceRole", data.aws_partition.current.partition)
}

# Always present: the script statement is never absent, so the policy is never empty.
resource "aws_iam_role_policy" "grants" {
  name   = format("%s-grants", local.job_name)
  role   = aws_iam_role.this.id
  policy = module.grants.policy_json
}

resource "aws_iam_role_policy_attachment" "managed" {
  count = length(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = var.managed_policy_arns[count.index]
}

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------

data "aws_subnet" "this" {
  count = local.has_network ? 1 : 0

  id = var.network.subnet_id
}

# The rule Glue requires on a connection's security group: inbound on every TCP port from
# the group itself, the path the workers use to talk to each other. It is in no error
# message until the run fails, so the group is the module's and the rule is not optional.
module "security_group" {
  source = "../security-group"

  count = local.has_network ? 1 : 0

  name        = format("%s-glue", local.job_name)
  description = format("Glue job %s", local.job_name)
  tags        = local.tags
  vpc_id      = data.aws_subnet.this[0].vpc_id

  ingress_self_rules = [
    { from_port = 0, to_port = 65535, protocol = "tcp", description = "Glue workers to each other" },
  ]
  allow_all_egress = true
}

resource "aws_glue_connection" "this" {
  count = local.has_network ? 1 : 0

  name            = local.job_name
  description     = format("Network for Glue job %s", local.job_name)
  connection_type = local.has_jdbc ? "JDBC" : "NETWORK"
  tags            = local.tags

  # The credentials stay in Secrets Manager: the connection holds the secret's name, and
  # Glue reads it with the job's role at run time.
  connection_properties = local.has_jdbc ? {
    JDBC_CONNECTION_URL = var.network.jdbc.url
    SECRET_ID           = var.resources.secrets[var.network.jdbc.secret].name
  } : {}

  physical_connection_requirements {
    subnet_id              = var.network.subnet_id
    availability_zone      = data.aws_subnet.this[0].availability_zone
    security_group_id_list = concat([module.security_group[0].id], var.network.security_group_ids)
  }

  lifecycle {
    precondition {
      condition     = !local.has_jdbc || try(var.resources.secrets[var.network.jdbc.secret].name, null) != null
      error_message = "network.jdbc.secret exists in `resources.secrets` but has no `name`, which is what the connection's SECRET_ID holds: set it in `resources`."
    }
  }
}

# ------------------------------------------------------------------------------
# Job
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  count = local.has_log_group ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.observability.log_retention_days
  kms_key_id        = var.observability.log_kms_key_id
  tags              = local.tags
}

resource "aws_glue_job" "this" {
  name        = local.job_name
  description = var.description
  role_arn    = aws_iam_role.this.arn
  tags        = local.tags

  glue_version           = local.glue_version
  execution_class        = var.execution_class
  security_configuration = var.security_configuration

  worker_type       = local.is_spark ? coalesce(var.worker_type, "G.1X") : null
  number_of_workers = local.is_spark ? coalesce(var.number_of_workers, 2) : null
  max_capacity      = local.is_spark ? null : coalesce(var.max_capacity, 0.0625)

  timeout     = var.timeout
  max_retries = var.max_retries

  command {
    name            = var.command
    script_location = local.script_location
    python_version  = local.python_version
  }

  execution_property {
    max_concurrent_runs = var.max_concurrent_runs
  }

  default_arguments = local.default_arguments
  connections       = local.connection_names

  # The log group must exist before the first run writes to it: created by Glue, it
  # would have no retention and could not be adopted without an import.
  depends_on = [aws_cloudwatch_log_group.this]

  lifecycle {
    # The existence of the referenced resources is checked by the variables' validations.
    # What is caught here is a resource that exists but does not expose the attribute
    # the job needs.
    precondition {
      condition = length(local.args_from_unresolved) == 0
      error_message = format(
        "args_from does not resolve: %s. The resource exists but the requested attribute is null: set it in `resources` or pick a different `attr`.",
        join(", ", local.args_from_unresolved),
      )
    }

    precondition {
      condition     = local.script_bucket.name != null
      error_message = format("script.bucket '%s' has no `name` in `resources.buckets`: the script's location cannot be built without it.", var.script.bucket)
    }

    precondition {
      condition     = var.temp_dir == null || try(local.temp_bucket.name, null) != null
      error_message = "temp_dir.bucket has no `name` in `resources.buckets`: the temp dir's location cannot be built without it."
    }
  }
}
