locals {
  bucket_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.bucket_name })

  uses_kms = var.encryption.kms_key_arn != null

  has_notifications = (
    length(var.notifications.queues) > 0 ||
    length(var.notifications.topics) > 0 ||
    length(var.notifications.functions) > 0
  )

  # The upstream module accepts the lifecycle rules as `any` and in some places
  # inspects the keys unguarded — `keys(filter)` fails if `filter` is null. Our
  # variables are typed, so every omitted attribute arrives as an explicit null: here
  # the rules are rebuilt with only the keys that are actually set.
  lifecycle_rules = [
    for r in var.lifecycle_rules : merge(
      {
        id      = r.id
        enabled = r.enabled
      },
      r.filter == null ? {} : {
        filter = { for k, v in {
          prefix                   = r.filter.prefix
          tags                     = r.filter.tags
          object_size_greater_than = r.filter.object_size_greater_than
          object_size_less_than    = r.filter.object_size_less_than
        } : k => v if v != null }
      },
      r.expiration == null ? {} : {
        expiration = { for k, v in {
          days                         = r.expiration.days
          date                         = r.expiration.date
          expired_object_delete_marker = r.expiration.expired_object_delete_marker
        } : k => v if v != null }
      },
      r.noncurrent_version_expiration == null ? {} : {
        noncurrent_version_expiration = { for k, v in {
          noncurrent_days           = r.noncurrent_version_expiration.noncurrent_days
          newer_noncurrent_versions = r.noncurrent_version_expiration.newer_noncurrent_versions
        } : k => v if v != null }
      },
      length(r.transition) == 0 ? {} : { transition = r.transition },
      length(r.noncurrent_version_transition) == 0 ? {} : { noncurrent_version_transition = r.noncurrent_version_transition },
      r.abort_incomplete_multipart_upload_days == null ? {} : {
        abort_incomplete_multipart_upload_days = r.abort_incomplete_multipart_upload_days
      },
    )
  ]

  cors_rules = [
    for r in var.cors_rules : { for k, v in {
      id              = r.id
      allowed_methods = r.allowed_methods
      allowed_origins = r.allowed_origins
      allowed_headers = r.allowed_headers
      expose_headers  = r.expose_headers
      max_age_seconds = r.max_age_seconds
    } : k => v if v != null }
  ]
}

module "s3" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.0"

  bucket        = local.bucket_name
  tags          = local.tags
  force_destroy = var.force_destroy

  # Always on, with no way to disable it from the module. Static web content goes
  # through modules/site, which uses CloudFront with Origin Access Control over a
  # private bucket.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  control_object_ownership = true
  object_ownership         = var.object_ownership

  versioning = {
    enabled = var.versioning_enabled
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = local.uses_kms ? "aws:kms" : "AES256"
        kms_master_key_id = var.encryption.kms_key_arn
      }
      # Cuts KMS calls drastically: without it, every GET and every PUT is a billable
      # KMS request.
      bucket_key_enabled = local.uses_kms
    }
  }

  cors_rule      = local.cors_rules
  lifecycle_rule = local.lifecycle_rules
  logging        = var.logging == null ? {} : { target_bucket = var.logging.target_bucket, target_prefix = coalesce(var.logging.target_prefix, "") }

  attach_policy = var.policy_json != null
  policy        = var.policy_json

  # Rejects non-TLS traffic and obsolete TLS versions: two statements that have no
  # downsides and that an audit always asks for.
  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true
}

# A single notification resource per bucket. S3 allows a single configuration and every
# write replaces the previous one entirely: two Terraform resources on the same bucket
# would overwrite each other in non-deterministic order.
resource "aws_s3_bucket_notification" "this" {
  count = local.has_notifications ? 1 : 0

  bucket = module.s3.s3_bucket_id

  dynamic "queue" {
    for_each = var.notifications.queues

    content {
      id            = queue.key
      queue_arn     = queue.value.queue_arn
      events        = queue.value.events
      filter_prefix = queue.value.filter_prefix
      filter_suffix = queue.value.filter_suffix
    }
  }

  dynamic "topic" {
    for_each = var.notifications.topics

    content {
      id            = topic.key
      topic_arn     = topic.value.topic_arn
      events        = topic.value.events
      filter_prefix = topic.value.filter_prefix
      filter_suffix = topic.value.filter_suffix
    }
  }

  dynamic "lambda_function" {
    for_each = var.notifications.functions

    content {
      id                  = lambda_function.key
      lambda_function_arn = lambda_function.value.function_arn
      events              = lambda_function.value.events
      filter_prefix       = lambda_function.value.filter_prefix
      filter_suffix       = lambda_function.value.filter_suffix
    }
  }

  depends_on = [aws_lambda_permission.notification]
}

# The invocation permission is created by the bucket, not by the function:
# notification and permission are the same declaration and cannot diverge. The
# dependency goes in this direction and not the other, so there is no cycle.
resource "aws_lambda_permission" "notification" {
  for_each = var.notifications.functions

  statement_id  = format("AllowS3-%s-%s", local.bucket_name, each.key)
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_arn
  principal     = "s3.amazonaws.com"
  source_arn    = format("arn:aws:s3:::%s", local.bucket_name)
}
