locals {
  function_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.function_name })

  registry = {
    buckets = var.resources.buckets
    tables  = var.resources.tables
    topics  = var.resources.topics
    queues  = var.resources.queues
    secrets = var.resources.secrets
  }

  # The attribute injected by default, per resource type. It reproduces what the
  # application normally expects: the name for buckets, tables and secrets, the ARN
  # for topics (the SDKs publish by ARN), the URL for queues.
  env_from_types = {
    bucket = { registry = "buckets", default_attr = "name" }
    table  = { registry = "tables", default_attr = "name" }
    topic  = { registry = "topics", default_attr = "arn" }
    queue  = { registry = "queues", default_attr = "url" }
    secret = { registry = "secrets", default_attr = "name" }
  }

  env_from_parsed = {
    for k, r in var.env_from : k => {
      type = (
        r.bucket != null ? "bucket" :
        r.table != null ? "table" :
        r.topic != null ? "topic" :
        r.queue != null ? "queue" :
        r.secret != null ? "secret" :
        null
      )
      name = coalesce(r.bucket, r.table, r.topic, r.queue, r.secret, "")
      attr = r.attr
    }
  }

  # The `try` is only there to route the error to the precondition, which reports it
  # with the name of the variable and of the resource. The resource's existence is
  # already checked by `env_from`'s validations: what is caught here is the case
  # where the resource exists but does not expose the requested attribute.
  env_from_resolved = {
    for k, p in local.env_from_parsed : k => try(
      local.registry[local.env_from_types[p.type].registry][p.name][coalesce(p.attr, local.env_from_types[p.type].default_attr)],
      null
    )
  }

  env_from_unresolved = sort([
    for k, v in local.env_from_resolved : format(
      "%s → %s/%s.%s",
      k,
      local.env_from_parsed[k].type,
      local.env_from_parsed[k].name,
      coalesce(local.env_from_parsed[k].attr, local.env_from_types[local.env_from_parsed[k].type].default_attr),
    ) if v == null
  ])

  environment_variables = merge(
    var.env,
    { for k, v in local.env_from_resolved : k => v if v != null },
  )

  # ----------------------------------------------------------------------------
  # Event source mapping
  # ----------------------------------------------------------------------------

  event_source_arns = {
    for k, s in var.event_sources : k => coalesce(
      s.event_source_arn,
      try(var.resources.queues[coalesce(s.queue, "")].arn, null),
    )
  }

  event_sources = {
    for k, s in var.event_sources : k => merge(
      {
        event_source_arn        = local.event_source_arns[k]
        enabled                 = s.enabled
        function_response_types = s.function_response_types
      },
      s.batch_size != null ? { batch_size = s.batch_size } : {},
      s.maximum_batching_window_in_seconds != null ? { maximum_batching_window_in_seconds = s.maximum_batching_window_in_seconds } : {},
      s.maximum_concurrency != null ? { scaling_config = { maximum_concurrency = s.maximum_concurrency } } : {},
      length(s.filter_patterns) > 0 ? { filter_criteria = { filter = [for p in s.filter_patterns : { pattern = p }] } } : {},
    )
  }

  # ----------------------------------------------------------------------------
  # Asynchronous invocation
  # ----------------------------------------------------------------------------

  # The two flags that follow feed `count` arguments in the upstream module, so they
  # must be resolvable at plan time. They derive from the *shape* of the inputs and
  # not from the ARNs: the ARNs come from resources not yet created and are unknown,
  # and a count depending on an unknown value makes the plan fail with
  # "Invalid count argument".
  has_policy       = length(var.grants) > 0 || length(var.extra_policy_statements) > 0
  has_async_target = var.async.enabled && var.async.on_failure != null

  # The outer `try` is necessary: `coalesce` with every argument null does not return
  # null, it raises an error that does not name the cause. This happens when
  # `on_failure` references a resource that is not in the registry — and in that case
  # the useful error comes from the precondition on the `arn` output.
  async_on_failure_arn = local.has_async_target ? try(coalesce(
    var.async.on_failure.arn,
    try(var.resources.queues[coalesce(var.async.on_failure.queue, "")].arn, null),
    try(var.resources.topics[coalesce(var.async.on_failure.topic, "")].arn, null),
  ), null) : null
}

module "grants" {
  source = "../grants"

  resources        = var.resources
  grants           = var.grants
  extra_statements = var.extra_policy_statements
}

module "lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.0"

  function_name = local.function_name
  description   = var.description
  tags          = local.tags

  # The module does not build packages: the build belongs to CI.
  create_package          = false
  package_type            = var.image_uri != null ? "Image" : "Zip"
  image_uri               = var.image_uri
  local_existing_package  = try(var.package.local_path, null)
  s3_existing_package     = try(var.package.s3_bucket, null) != null ? { bucket = var.package.s3_bucket, key = var.package.s3_key } : null
  ignore_source_code_hash = var.ignore_code_changes

  handler       = var.image_uri != null ? null : var.handler
  runtime       = var.image_uri != null ? null : var.runtime
  architectures = var.architectures
  layers        = var.layers

  memory_size                    = var.memory_size
  timeout                        = var.timeout
  ephemeral_storage_size         = var.ephemeral_storage_size
  reserved_concurrent_executions = var.reserved_concurrent_executions
  environment_variables          = local.environment_variables

  vpc_subnet_ids         = try(var.vpc.subnet_ids, null)
  vpc_security_group_ids = try(var.vpc.security_group_ids, null)

  # Conditional: ENI permissions on a function outside the VPC are a pointless
  # widening of its surface.
  attach_network_policy = var.vpc != null

  # Log
  cloudwatch_logs_retention_in_days = var.observability.log_retention_days
  cloudwatch_logs_kms_key_id        = var.observability.log_kms_key_id
  logging_log_format                = var.observability.log_format
  logging_application_log_level     = var.observability.log_format == "JSON" ? var.observability.log_level : null
  logging_system_log_level          = var.observability.log_format == "JSON" ? var.observability.system_log_level : null

  # Tracing
  tracing_mode          = var.observability.tracing ? "Active" : null
  attach_tracing_policy = var.observability.tracing

  # Asynchronous invocation: without an on-failure destination an event that runs
  # out of attempts disappears without a trace.
  create_async_event_config    = var.async.enabled
  maximum_retry_attempts       = var.async.enabled ? var.async.maximum_retry_attempts : null
  maximum_event_age_in_seconds = var.async.enabled ? var.async.maximum_event_age_in_seconds : null
  destination_on_failure       = local.async_on_failure_arn
  attach_async_event_policy    = local.has_async_target

  # Capability-derived IAM
  attach_policy_json = local.has_policy
  policy_json        = local.has_policy ? module.grants.policy_json : null

  attach_policies    = length(var.managed_policy_arns) > 0
  number_of_policies = length(var.managed_policy_arns)
  policies           = var.managed_policy_arns

  event_source_mapping = local.event_sources

  allowed_triggers = {
    for k, t in var.allowed_triggers : k => merge(
      {
        principal = t.principal
        action    = t.action
      },
      t.source_arn != null ? { source_arn = t.source_arn } : {},
      t.statement_id != null ? { statement_id = t.statement_id } : {},
      t.principal_org != null ? { principal_org_id = t.principal_org } : {},
    )
  }
}
