data "aws_partition" "current" {}

locals {
  tags = var.tags

  # ----------------------------------------------------------------------------
  # The buckets enter the registry with an ARN and a name **computed from the
  # prefix**, not read from the module that creates them.
  #
  # This breaks a real cycle: a function can read from a bucket (so it needs its ARN
  # in the registry) and a bucket can notify a function (so it needs its ARN). With
  # real references in both directions Terraform detects a cycle between the two
  # module blocks and refuses to proceed.
  #
  # S3 ARNs contain neither region nor account, so they are entirely derivable from
  # the name: the static computation is exact, not an approximation. The only
  # consequence is that the function's IAM does not wait for the bucket's creation,
  # which for a policy is irrelevant.
  # ----------------------------------------------------------------------------
  bucket_names = { for k in keys(var.buckets) : k => format("%s-%s", var.prefix, k) }

  bucket_registry = {
    for k, name in local.bucket_names : k => {
      arn         = format("arn:%s:s3:::%s", data.aws_partition.current.partition, name)
      name        = name
      url         = null
      kms_key_arn = var.buckets[k].kms_key_arn
    }
  }

  # The registry passed to every function. The table, topic, queue and secret entries come
  # from the modules that create them; the bucket ones are computed.
  resources = {
    buckets = local.bucket_registry
    tables  = { for k, m in module.tables : k => m.registry_entry }
    topics  = { for k, m in module.topics : k => m.registry_entry }
    queues  = { for k, m in module.queues : k => m.registry_entry }
    secrets = { for k, m in module.secrets : k => m.registry_entry }
  }

  # ----------------------------------------------------------------------------
  # Inverting the subscriptions: from the topic side, where they read naturally, to
  # the queue side, where SQS requires them to converge into a single policy
  # document.
  #
  # It is the work that belongs to the composition. The subscription's key is the
  # topic's key, so that the policy's Sid says where it comes from.
  # ----------------------------------------------------------------------------
  queue_subscriptions = {
    for qk in keys(var.queues) : qk => {
      for tk, t in var.topics : tk => {
        topic_arn            = module.topics[tk].arn
        filter_policy        = t.to_queues[qk].filter_policy
        filter_policy_scope  = t.to_queues[qk].filter_policy_scope
        raw_message_delivery = t.to_queues[qk].raw_message_delivery
      } if contains(keys(t.to_queues), qk)
    }
  }

  # Every bucket declared as a source becomes a statement in the queue's policy, with the ARN
  # computed statically for the same reason as above.
  queue_bucket_sources = {
    for qk, q in var.queues : qk => [
      for bk in q.allow_send_from_buckets : {
        service        = "s3"
        source_arn     = local.bucket_registry[bk].arn
        source_account = null
      } if contains(keys(local.bucket_registry), bk)
    ]
  }

  # ----------------------------------------------------------------------------
  # Cross-references are filtered and the lookups are defensive.
  #
  # This is not a silent fallback: a reference that does not exist appears in
  # `wiring_errors` and makes the plan fail with the name of the wrong key.
  # Filtering only serves to route the error to the precondition, instead of letting
  # it surface as an "Invalid index" on a module block, which says neither which
  # reference is wrong nor where it is declared.
  # ----------------------------------------------------------------------------
  bucket_notifications = {
    for bk, b in var.buckets : bk => {
      queues = {
        for nk, n in b.notifications.queues : nk => n
        if contains(keys(var.queues), n.queue)
      }
      topics = {
        for nk, n in b.notifications.topics : nk => n
        if contains(keys(var.topics), n.topic)
      }
      functions = {
        for nk, n in b.notifications.functions : nk => n
        if contains(keys(var.functions), n.function)
      }
    }
  }

  function_security_group_ids = {
    for fk, f in var.functions : fk => f.vpc == null ? [] : [
      for sk in f.vpc.security_group_keys : module.security_groups[sk].id
      if contains(keys(var.security_groups), sk)
    ]
  }

  # A uniform shape with null where it does not apply: the two branches of a conditional must
  # have the same type.
  function_async_on_failure = {
    for fk, f in var.functions : fk => (
      f.async.on_failure_queue != null && contains(keys(var.queues), coalesce(f.async.on_failure_queue, "x")) ? {
        queue = f.async.on_failure_queue
        topic = null
        arn   = null
        } : f.async.on_failure_topic != null && contains(keys(var.topics), coalesce(f.async.on_failure_topic, "x")) ? {
        queue = null
        topic = f.async.on_failure_topic
        arn   = null
      } : null
    )
  }

  # The target type is known here, where it is declared by key. Inferring it downstream from
  # the ARN does not work: the ARNs come from resources not yet created.
  schedule_target_types = {
    for k, s in var.schedules : k => (
      s.target_function != null ? "lambda" :
      s.target_queue != null ? "sqs" :
      "sfn"
    )
  }

  # A schedule with a wrong reference is not instantiated at all: if a null target reached it,
  # its own validation would fail, with a message that talks about ARNs and does not say which
  # key is wrong. The useful error comes from `wiring`'s precondition.
  valid_schedules = {
    for k, s in var.schedules : k => s
    if(s.target_function == null || contains(keys(var.functions), coalesce(s.target_function, "x"))) &&
    (s.target_queue == null || contains(keys(var.queues), coalesce(s.target_queue, "x"))) &&
    (s.dead_letter_queue == null || contains(keys(var.queues), coalesce(s.dead_letter_queue, "x")))
  }

  # ----------------------------------------------------------------------------
  # Alarms
  #
  # The topic is created before the primitives and its ARN is wired into all of
  # them: there is no such case as an alarm created and delivered to nobody.
  # ----------------------------------------------------------------------------
  create_alarm_topic = var.observability.enabled
  alarm_actions      = local.create_alarm_topic ? [module.alarm_topic[0].arn] : []

  # ----------------------------------------------------------------------------
  # Checking the cross-references.
  #
  # These are the references this module introduces, that is the by-key ones between
  # one primitive and another. The ones internal to a primitive — `env_from`,
  # `grants`, an API's routes — are checked by the modules that receive them, with
  # their own messages.
  # ----------------------------------------------------------------------------
  wiring_errors = concat(
    flatten([
      for tk, t in var.topics : [
        for qk in keys(t.to_queues) : format("topics['%s'].to_queues references the queue '%s', which is not in `queues`", tk, qk)
        if !contains(keys(var.queues), qk)
      ]
    ]),
    flatten([
      for qk, q in var.queues : [
        for bk in q.allow_send_from_buckets : format("queues['%s'].allow_send_from_buckets references the bucket '%s', which is not in `buckets`", qk, bk)
        if !contains(keys(var.buckets), bk)
      ]
    ]),
    flatten([
      for bk, b in var.buckets : [
        for nk, n in b.notifications.queues : format("buckets['%s'].notifications.queues['%s'] references the queue '%s', which is not in `queues`", bk, nk, n.queue)
        if !contains(keys(var.queues), n.queue)
      ]
    ]),
    flatten([
      for bk, b in var.buckets : [
        for nk, n in b.notifications.topics : format("buckets['%s'].notifications.topics['%s'] references the topic '%s', which is not in `topics`", bk, nk, n.topic)
        if !contains(keys(var.topics), n.topic)
      ]
    ]),
    flatten([
      for bk, b in var.buckets : [
        for nk, n in b.notifications.functions : format("buckets['%s'].notifications.functions['%s'] references the function '%s', which is not in `functions`", bk, nk, n.function)
        if !contains(keys(var.functions), n.function)
      ]
    ]),
    flatten([
      for fk, f in var.functions : [
        for sk in try(f.vpc.security_group_keys, []) : format("functions['%s'].vpc.security_group_keys references the security group '%s', which is not in `security_groups`", fk, sk)
        if !contains(keys(var.security_groups), sk)
      ]
    ]),
    [
      for fk, f in var.functions : format("functions['%s'].async.on_failure_queue references the queue '%s', which is not in `queues`", fk, f.async.on_failure_queue)
      if f.async.on_failure_queue != null && !contains(keys(var.queues), coalesce(f.async.on_failure_queue, "x"))
    ],
    [
      for fk, f in var.functions : format("functions['%s'].async.on_failure_topic references the topic '%s', which is not in `topics`", fk, f.async.on_failure_topic)
      if f.async.on_failure_topic != null && !contains(keys(var.topics), coalesce(f.async.on_failure_topic, "x"))
    ],
    [
      for sk, s in var.schedules : format("schedules['%s'].target_function references the function '%s', which is not in `functions`", sk, s.target_function)
      if s.target_function != null && !contains(keys(var.functions), coalesce(s.target_function, "x"))
    ],
    [
      for sk, s in var.schedules : format("schedules['%s'].target_queue references the queue '%s', which is not in `queues`", sk, s.target_queue)
      if s.target_queue != null && !contains(keys(var.queues), coalesce(s.target_queue, "x"))
    ],
    [
      for sk, s in var.schedules : format("schedules['%s'].dead_letter_queue references the queue '%s', which is not in `queues`", sk, s.dead_letter_queue)
      if s.dead_letter_queue != null && !contains(keys(var.queues), coalesce(s.dead_letter_queue, "x"))
    ],
    flatten([
      for rk, r in var.registries : [
        for fk in r.lambda_read_access_functions : format("registries['%s'].lambda_read_access_functions references the function '%s', which is not in `functions`", rk, fk)
        if !contains(keys(var.functions), fk)
      ]
    ]),
    # A site creates a bucket named `<prefix>-<key>`: a namesake key in `buckets` would
    # produce two resources fighting over the same name, and the error would come from AWS
    # at apply time.
    [
      for sk in keys(var.sites) : format("sites['%s'] and buckets['%s'] would generate two buckets with the same name '%s-%s'", sk, sk, var.prefix, sk)
      if contains(keys(var.buckets), sk)
    ],
  )
}
