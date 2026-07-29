# The module has neither providers nor resources: these tests run without
# credentials and without mocks, and check the actual content of the generated
# policies.

variables {
  resources = {
    buckets = {
      documents = { arn = "arn:aws:s3:::acme-prod-documents", name = "acme-prod-documents" }
      assets    = { arn = "arn:aws:s3:::acme-prod-assets", name = "acme-prod-assets" }
    }
    tables = {
      tenants = { arn = "arn:aws:dynamodb:eu-west-1:111122223333:table/acme-prod-tenants", name = "acme-prod-tenants" }
    }
    topics = {
      # Deliberately a namesake of the queue below: this is the case that makes the
      # type prefix in the grant keys necessary.
      operations = { arn = "arn:aws:sns:eu-west-1:111122223333:acme-prod-operations", name = "acme-prod-operations" }
    }
    queues = {
      operations = { arn = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-operations", name = "acme-prod-operations", url = "https://sqs.eu-west-1.amazonaws.com/111122223333/acme-prod-operations" }
      encrypted  = { arn = "arn:aws:sqs:eu-west-1:111122223333:acme-prod-encrypted", name = "acme-prod-encrypted", kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/abcd-1234" }
    }
    secrets = {
      mongodb = { arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:acme-prod-mongodb-AbCdEf", name = "acme-prod-mongodb" }
    }
  }
}

run "no_grants_no_policy" {
  variables {
    grants = {}
  }

  # The null is the contract: attaching a policy with an empty Statement is an error
  # on the AWS side, so the caller must be able to tell "empty" from "absent".
  assert {
    condition     = output.policy_json == null
    error_message = "With no grants policy_json must be null, not an empty document."
  }

  assert {
    condition     = output.has_policy == false
    error_message = "has_policy must be false with no grants."
  }
}

run "bucket_read_write_separates_bucket_from_objects" {
  variables {
    grants = {
      "bucket/documents" = ["read", "write"]
    }
  }

  # ListBucket is an action on the bucket, GetObject/PutObject are on the objects:
  # granting them on the same ARN is the classic mistake that makes the policy
  # ineffective.
  assert {
    condition     = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "BucketDocumentsSelf"]).Action == ["s3:ListBucket"]
    error_message = "Only ListBucket must be on the bucket."
  }

  assert {
    condition     = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "BucketDocumentsSelf"]).Resource == ["arn:aws:s3:::acme-prod-documents"]
    error_message = "The 'self' statement must point at the bucket's ARN without a suffix."
  }

  assert {
    condition = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "BucketDocumentsChildren"]).Action == [
      "s3:AbortMultipartUpload", "s3:DeleteObject", "s3:GetObject", "s3:PutObject",
    ]
    error_message = "The actions on the objects must be merged and sorted into a single statement."
  }

  assert {
    condition     = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "BucketDocumentsChildren"]).Resource == ["arn:aws:s3:::acme-prod-documents/*"]
    error_message = "The statement on the objects must use the ARN with the /* suffix."
  }

  assert {
    condition     = length(jsondecode(output.policy_json).Statement) == 2
    error_message = "Two capabilities on the same resource must produce two statements (one per scope), not four."
  }
}

run "table_read_includes_indexes_and_scan_stays_separate" {
  variables {
    grants = {
      "table/tenants" = ["read"]
    }
  }

  # A Query on a GSI requires the index's ARN: without the children the policy looks
  # correct and only fails at runtime on the first query against an index.
  assert {
    condition = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "TableTenantsBoth"]).Resource == [
      "arn:aws:dynamodb:eu-west-1:111122223333:table/acme-prod-tenants",
      "arn:aws:dynamodb:eu-west-1:111122223333:table/acme-prod-tenants/index/*",
    ]
    error_message = "read on a table must cover the table and its indexes."
  }

  assert {
    condition     = !contains(one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "TableTenantsBoth"]).Action, "dynamodb:Scan")
    error_message = "read must not include Scan: it is a separate capability."
  }
}

run "scan_merges_with_read_in_the_same_scope" {
  variables {
    grants = {
      "table/tenants" = ["read", "scan"]
    }
  }

  assert {
    condition = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "TableTenantsBoth"]).Action == [
      "dynamodb:BatchGetItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan",
    ]
    error_message = "read and scan on the same scope must merge into a single sorted statement."
  }
}

run "namesake_topic_and_queue_do_not_collide" {
  variables {
    grants = {
      "topic/operations" = ["publish"]
      "queue/operations" = ["consume"]
    }
  }

  # This is why the grant keys are prefixed by type: in the real tfvars a topic and
  # a queue are both called "operations".
  assert {
    condition     = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "TopicOperationsSelf"]).Resource == ["arn:aws:sns:eu-west-1:111122223333:acme-prod-operations"]
    error_message = "The grant on the topic must resolve to the SNS ARN."
  }

  assert {
    condition     = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "QueueOperationsSelf"]).Resource == ["arn:aws:sqs:eu-west-1:111122223333:acme-prod-operations"]
    error_message = "The grant on the queue must resolve to the SQS ARN."
  }

  assert {
    condition = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "QueueOperationsSelf"]).Action == [
      "sqs:ChangeMessageVisibility", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ReceiveMessage",
    ]
    error_message = "consume must grant the four consumption actions, sorted."
  }
}

run "secret_read" {
  variables {
    grants = {
      "secret/mongodb" = ["read"]
    }
  }

  assert {
    condition = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "SecretMongodbSelf"]).Action == [
      "secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue",
    ]
    error_message = "read on a secret must grant GetSecretValue and DescribeSecret."
  }
}

run "a_cmk_adds_the_kms_permissions" {
  variables {
    grants = {
      "queue/encrypted" = ["consume", "publish"]
    }
  }

  # consume wants Decrypt, publish wants GenerateDataKey too: without these the
  # encrypted queue fails at runtime with an AccessDenied on KMS, not on SQS.
  assert {
    condition = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "KmsAccess0"]).Action == [
      "kms:Decrypt", "kms:GenerateDataKey",
    ]
    error_message = "The KMS permissions must be the union of the granted capabilities."
  }

  assert {
    condition     = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "KmsAccess0"]).Resource == ["arn:aws:kms:eu-west-1:111122223333:key/abcd-1234"]
    error_message = "The KMS statement must point at the resource's CMK."
  }
}

run "no_kms_without_a_cmk" {
  variables {
    grants = {
      "queue/operations" = ["consume"]
    }
  }

  assert {
    condition     = length([for s in jsondecode(output.policy_json).Statement : s if startswith(s.Sid, "KmsAccess")]) == 0
    error_message = "Without a CMK no KMS statement must appear."
  }
}

run "extra_statements_with_a_condition" {
  variables {
    grants = {}
    extra_statements = [
      {
        sid       = "SendEmail"
        actions   = ["ses:SendEmail", "ses:SendRawEmail"]
        resources = ["*"]
        condition = [
          { test = "StringEquals", variable = "ses:FromAddress", values = ["noreply@acme.example"] },
          { test = "StringEquals", variable = "aws:RequestedRegion", values = ["eu-west-1"] },
        ]
      }
    ]
  }

  # Conditions with the same test must be merged into a single object: IAM does not
  # accept two "StringEquals" keys in the same Condition.
  assert {
    condition = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "SendEmail"]).Condition == {
      StringEquals = {
        "ses:FromAddress"     = ["noreply@acme.example"]
        "aws:RequestedRegion" = ["eu-west-1"]
      }
    }
    error_message = "Conditions with the same test must be grouped under a single key."
  }

  assert {
    condition     = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "SendEmail"]).Effect == "Allow"
    error_message = "The default effect must be Allow."
  }
}

run "a_statement_without_a_condition_has_no_such_key" {
  variables {
    grants = {
      "secret/mongodb" = ["read"]
    }
  }

  # If Condition were emitted as null or as an empty object, AWS would reject the
  # policy: the key must simply not be there.
  assert {
    condition     = !contains(keys(one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "SecretMongodbSelf"])), "Condition")
    error_message = "A statement without conditions must not have the Condition key."
  }
}

run "deterministic_output" {
  variables {
    grants = {
      "queue/operations" = ["consume"]
      "bucket/assets"    = ["read"]
      "table/tenants"    = ["read", "scan"]
      "secret/mongodb"   = ["read"]
    }
  }

  # The order of the statements must not depend on map iteration order: a spurious
  # diff on a policy is indistinguishable from a real change.
  assert {
    condition = [for s in jsondecode(output.policy_json).Statement : s.Sid] == [
      "BucketAssetsChildren", "BucketAssetsSelf", "QueueOperationsSelf", "SecretMongodbSelf", "TableTenantsBoth",
    ]
    error_message = "The statements must be ordered stably by Sid."
  }
}
