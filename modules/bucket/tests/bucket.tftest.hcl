mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  prefix = "acme-prod"
  name   = "documents"
}

run "naming_and_static_arn" {
  command = plan

  # The static ARN is computed from the name and not from the resource: it is there to
  # break the cycle with the queues and topics that have to authorize S3 to write.
  assert {
    condition     = output.static_arn == "arn:aws:s3:::acme-prod-documents"
    error_message = "The static ARN must be computable from the name alone."
  }
}

run "no_notifications_by_default" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_notification.this) == 0
    error_message = "With no declared notifications the notification resource must not exist."
  }

  assert {
    condition     = length(aws_lambda_permission.notification) == 0
    error_message = "With no notifications towards functions no invocation permissions must exist."
  }
}

run "notifications_towards_different_destinations_in_a_single_resource" {
  command = plan

  variables {
    notifications = {
      queues = {
        ingest = {
          queue_arn     = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-ingest"
          events        = ["s3:ObjectCreated:*"]
          filter_prefix = "incoming/"
        }
      }
      topics = {
        audit = {
          topic_arn = "arn:aws:sns:eu-west-1:111122223333:acme-prod-audit"
          events    = ["s3:ObjectRemoved:*"]
        }
      }
      functions = {
        thumbnailer = {
          function_arn  = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-thumbnailer"
          events        = ["s3:ObjectCreated:Put"]
          filter_suffix = ".jpg"
        }
      }
    }
  }

  # S3 allows a single notification configuration per bucket and every write replaces
  # the previous one entirely: three destinations must converge into a single resource.
  assert {
    condition     = length(aws_s3_bucket_notification.this) == 1
    error_message = "All the notifications must converge into a single resource: S3 allows one per bucket."
  }

  assert {
    condition = output.notification_ids == {
      queues    = tolist(["ingest"])
      topics    = tolist(["audit"])
      functions = tolist(["thumbnailer"])
    }
    error_message = "The notification ids must match the declared keys."
  }

  # The invocation permission is created by the bucket alongside the notification: they
  # are the same declaration and cannot diverge.
  assert {
    condition     = length(aws_lambda_permission.notification) == 1
    error_message = "A notification towards a function must also create the invocation permission."
  }

  assert {
    condition     = aws_lambda_permission.notification["thumbnailer"].source_arn == "arn:aws:s3:::acme-prod-documents"
    error_message = "The permission must be scoped to this bucket."
  }

  assert {
    condition     = aws_lambda_permission.notification["thumbnailer"].principal == "s3.amazonaws.com"
    error_message = "The permission's principal must be the S3 service."
  }
}

run "registry_entry_with_a_cmk" {
  command = plan

  variables {
    encryption = { kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/abcd-1234" }
  }

  assert {
    condition     = output.registry_entry.kms_key_arn == "arn:aws:kms:eu-west-1:111122223333:key/abcd-1234"
    error_message = "The registry entry must carry the bucket's CMK."
  }
}

run "lifecycle_and_cors" {
  command = plan

  variables {
    cors_rules = [
      {
        allowed_methods = ["GET", "HEAD"]
        allowed_origins = ["https://app.acme.example"]
        max_age_seconds = 3600
      }
    ]
    lifecycle_rules = [
      {
        id = "expire-old-versions"
        noncurrent_version_expiration = {
          noncurrent_days = 30
        }
        # The fragments of aborted uploads are not visible among the objects but are
        # billed indefinitely.
        abort_incomplete_multipart_upload_days = 7
      }
    ]
  }

  assert {
    condition     = output.static_arn == "arn:aws:s3:::acme-prod-documents"
    error_message = "The bucket with lifecycle and CORS rules must be created normally."
  }
}
