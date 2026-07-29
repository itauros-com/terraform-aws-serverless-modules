locals {
  # Maps the type prefix used in the `grants` keys to the registry key, the IAM
  # service and the ARN suffix of child resources.
  #
  # `child_suffix` exists because some actions do not operate on the resource's ARN
  # but on its children: `s3:GetObject` wants `arn/*`, `dynamodb:Query` on a
  # secondary index wants `arn/index/*`. Where it is null the resource has no
  # children.
  ref_types = {
    bucket = { registry = "buckets", service = "s3", child_suffix = "/*" }
    table  = { registry = "tables", service = "dynamodb", child_suffix = "/index/*" }
    topic  = { registry = "topics", service = "sns", child_suffix = null }
    queue  = { registry = "queues", service = "sqs", child_suffix = null }
    secret = { registry = "secrets", service = "secretsmanager", child_suffix = null }
  }

  # THE TABLE. The single source of truth for the capability → action translation.
  #
  # `scope` is "self" (the resource's ARN), "children" (the ARN with the suffix) or
  # "both". The actions are deliberately narrow: `read` on a table does not include
  # `Scan`, which is a separate capability, because scanning a large table is a
  # design decision and not a permissions detail.
  capabilities = {
    s3 = {
      read = [
        { actions = ["s3:ListBucket"], scope = "self" },
        { actions = ["s3:GetObject"], scope = "children" },
      ]
      write = [
        { actions = ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"], scope = "children" },
      ]
    }
    dynamodb = {
      # Query is granted on the children too: querying a GSI requires the index's
      # ARN, not the table's.
      read = [
        { actions = ["dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query"], scope = "both" },
      ]
      write = [
        { actions = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:BatchWriteItem"], scope = "self" },
      ]
      scan = [
        { actions = ["dynamodb:Scan"], scope = "both" },
      ]
    }
    sns = {
      publish = [
        { actions = ["sns:Publish"], scope = "self" },
      ]
    }
    sqs = {
      publish = [
        { actions = ["sqs:SendMessage"], scope = "self" },
      ]
      consume = [
        { actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], scope = "self" },
      ]
    }
    secretsmanager = {
      read = [
        { actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], scope = "self" },
      ]
    }
  }

  # Implicit KMS permissions when the resource is encrypted with a CMK. Writing to
  # an encrypted queue or bucket requires both GenerateDataKey and Decrypt.
  kms_actions = {
    read    = ["kms:Decrypt"]
    scan    = ["kms:Decrypt"]
    consume = ["kms:Decrypt"]
    write   = ["kms:Decrypt", "kms:GenerateDataKey"]
    publish = ["kms:Decrypt", "kms:GenerateDataKey"]
  }

  registry = {
    buckets = var.resources.buckets
    tables  = var.resources.tables
    topics  = var.resources.topics
    queues  = var.resources.queues
    secrets = var.resources.secrets
  }

  parsed = {
    for key, caps in var.grants : key => {
      type = split("/", key)[0]
      name = join("/", slice(split("/", key), 1, length(split("/", key))))
      caps = caps
    }
  }

  # Defensive lookup: null when the resource is not in the registry. The `try` is
  # there to route the error to the output preconditions, which report it with the
  # name of the missing key, instead of blowing up indexing with an unreadable
  # message. It is not a silent fallback: without the resource the plan fails all
  # the same.
  entries = {
    for key, g in local.parsed : key => try(local.registry[local.ref_types[g.type].registry][g.name], null)
  }

  missing_refs = sort([for key, entry in local.entries : key if entry == null])

  unknown_capabilities = sort(flatten([
    for key, g in local.parsed : [
      for cap in g.caps : format("%s → '%s'", key, cap)
      if !contains(keys(try(local.capabilities[local.ref_types[g.type].service], {})), cap)
    ]
  ]))

  # Computed only over the intact grants, so that errors are reported by the
  # preconditions instead of surfacing as indexing crashes.
  valid_keys = [
    for key, g in local.parsed : key
    if local.entries[key] != null && length([
      for cap in g.caps : cap
      if !contains(keys(try(local.capabilities[local.ref_types[g.type].service], {})), cap)
    ]) == 0
  ]

  # Capability → (key, scope, action) expansion. One capability can produce several
  # scopes: `read` on a bucket is ListBucket on the bucket and GetObject on the
  # objects.
  expanded = flatten([
    for key in local.valid_keys : [
      for cap in local.parsed[key].caps : [
        for spec in local.capabilities[local.ref_types[local.parsed[key].type].service][cap] : {
          key     = key
          scope   = spec.scope
          actions = spec.actions
        }
      ]
    ]
  ])

  arns = {
    for key in local.valid_keys : key => {
      self = local.entries[key].arn
      children = local.ref_types[local.parsed[key].type].child_suffix != null ? format(
        "%s%s", local.entries[key].arn, local.ref_types[local.parsed[key].type].child_suffix
      ) : null
    }
  }

  # One statement per (resource, scope), with the actions merged and sorted: two
  # capabilities on the same resource do not produce duplicate statements.
  grant_groups = {
    for pair in distinct([for e in local.expanded : format("%s|%s", e.key, e.scope)]) : pair => {
      key     = split("|", pair)[0]
      scope   = split("|", pair)[1]
      actions = sort(distinct(flatten([for e in local.expanded : e.actions if format("%s|%s", e.key, e.scope) == pair])))
    }
  }

  grant_statements = [
    for pair in sort(keys(local.grant_groups)) : {
      sid = format(
        "%s%s",
        replace(title(replace(local.grant_groups[pair].key, "/[^0-9A-Za-z]+/", " ")), " ", ""),
        title(local.grant_groups[pair].scope),
      )
      effect  = "Allow"
      actions = local.grant_groups[pair].actions
      resources = (
        local.grant_groups[pair].scope == "self" ? [local.arns[local.grant_groups[pair].key].self] :
        local.grant_groups[pair].scope == "children" ? compact([local.arns[local.grant_groups[pair].key].children]) :
        compact([local.arns[local.grant_groups[pair].key].self, local.arns[local.grant_groups[pair].key].children])
      )
      condition = []
    }
  ]

  kms_pairs = flatten([
    for key in local.valid_keys : [
      for cap in local.parsed[key].caps : {
        arn     = local.entries[key].kms_key_arn
        actions = local.kms_actions[cap]
      } if local.entries[key].kms_key_arn != null
    ]
  ])

  kms_key_arns = sort(distinct([for p in local.kms_pairs : p.arn]))

  kms_statements = [
    for idx, arn in local.kms_key_arns : {
      sid       = format("KmsAccess%d", idx)
      effect    = "Allow"
      actions   = sort(distinct(flatten([for p in local.kms_pairs : p.actions if p.arn == arn])))
      resources = [arn]
      condition = []
    }
  ]

  extra_statements = [
    for idx, s in var.extra_statements : {
      sid       = coalesce(s.sid, format("Extra%d", idx))
      effect    = s.effect
      actions   = s.actions
      resources = s.resources
      condition = s.condition
    }
  ]

  all_statements = concat(local.grant_statements, local.kms_statements, local.extra_statements)

  # A tuple, not a list: statements with and without a `Condition` have different
  # shapes and a tuple does not force type unification. jsonencode serializes it as
  # a JSON array.
  policy_document = {
    Version = "2012-10-17"
    Statement = [
      for s in local.all_statements : merge(
        {
          Sid      = s.sid
          Effect   = s.effect
          Action   = s.actions
          Resource = s.resources
        },
        length(s.condition) > 0 ? {
          Condition = {
            for test in distinct([for c in s.condition : c.test]) : test => {
              for c in s.condition : c.variable => c.values if c.test == test
            }
          }
        } : {},
      )
    ]
  }
}
