locals {
  secret_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.secret_name })

  has_policy = length(var.policy_statements) > 0

  # A version is created only when a value is actually supplied. This is the whole point
  # of the module, and it is why the resources below are written natively instead of
  # wrapping `terraform-aws-modules/secrets-manager`.
  #
  # That module always creates exactly one `aws_secretsmanager_secret_version`: its two
  # counts are complementary and there is no way to get zero. A version with no value is
  # rejected by AWS with `InvalidRequestException: You must provide either SecretString
  # or SecretBinary`, so "create the secret and let somebody else write the value" — the
  # documented and recommended path — could be planned but never applied.
  #
  # A secret with no versions is a perfectly valid state in Secrets Manager: `CreateSecret`
  # does not require a value. It is `PutSecretValue` that does.
  #
  # It also fails better. An unpopulated secret makes `GetSecretValue` return
  # `ResourceNotFoundException`, which names the problem. A placeholder value would be
  # handed to the application, which would fail further downstream against whatever it
  # authenticates to — an error that points somewhere else entirely.
  has_value = var.initial_value != null

  # Two resources with complementary counts, because `lifecycle.ignore_changes` cannot be
  # made conditional. Only one of them ever exists.
  manage_value = local.has_value && !var.ignore_value_changes
  freeze_value = local.has_value && var.ignore_value_changes
}

resource "aws_secretsmanager_secret" "this" {
  name        = local.secret_name
  description = var.description
  tags        = local.tags

  kms_key_id              = var.kms_key_id
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "this" {
  count = local.manage_value ? 1 : 0

  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = var.initial_value
}

resource "aws_secretsmanager_secret_version" "frozen" {
  count = local.freeze_value ? 1 : 0

  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = var.initial_value

  # The real value is written by somebody else. Without this, every plan would try to
  # bring the secret back to the content Terraform knows about, wiping out the credential
  # in use.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# The statement shape is the one the upstream module accepted, so the variable contract is
# unchanged. `try` on the optional fields: the variable is `map(any)`, so an omitted field
# is absent rather than null.
data "aws_iam_policy_document" "this" {
  count = local.has_policy ? 1 : 0

  dynamic "statement" {
    for_each = var.policy_statements

    content {
      sid           = try(statement.value.sid, statement.key)
      effect        = try(statement.value.effect, "Allow")
      actions       = try(statement.value.actions, null)
      not_actions   = try(statement.value.not_actions, null)
      resources     = try(statement.value.resources, null)
      not_resources = try(statement.value.not_resources, null)

      dynamic "principals" {
        for_each = try(statement.value.principals, [])

        content {
          type        = principals.value.type
          identifiers = principals.value.identifiers
        }
      }

      dynamic "condition" {
        for_each = try(statement.value.condition, [])

        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_secretsmanager_secret_policy" "this" {
  count = local.has_policy ? 1 : 0

  secret_arn = aws_secretsmanager_secret.this.arn
  policy     = data.aws_iam_policy_document.this[0].json

  # Rejects a resource policy that would grant public access.
  block_public_policy = true
}

resource "aws_secretsmanager_secret_rotation" "this" {
  count = var.rotation.enabled ? 1 : 0

  secret_id           = aws_secretsmanager_secret.this.id
  rotation_lambda_arn = var.rotation.lambda_arn
  rotate_immediately  = var.rotation.rotate_immediately

  rotation_rules {
    automatically_after_days = var.rotation.automatically_after_days
    schedule_expression      = var.rotation.schedule_expression
    duration                 = var.rotation.duration
  }
}
