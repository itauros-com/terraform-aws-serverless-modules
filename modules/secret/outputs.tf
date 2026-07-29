output "arn" {
  description = "The secret's ARN."
  value       = aws_secretsmanager_secret.this.arn
}

output "name" {
  description = "The secret's name, already prefixed. It is what you pass to `GetSecretValue` — which also accepts the ARN, so both work."
  value       = aws_secretsmanager_secret.this.name
}

output "id" {
  description = "The secret's ID, which for Secrets Manager **is the ARN** and not the name. Kept for symmetry with the other modules; prefer `arn` or `name`, which say what they are."
  value       = aws_secretsmanager_secret.this.id
}

output "registry_entry" {
  description = <<-EOT
    The entry to put into the consumers' `resources` registry, already in the expected
    shape, CMK included.

        resources = { secrets = { database = module.database.registry_entry } }
  EOT
  value = {
    arn         = aws_secretsmanager_secret.this.arn
    name        = aws_secretsmanager_secret.this.name
    kms_key_arn = var.kms_key_id
  }
}

output "value_managed_by_terraform" {
  description = <<-EOT
    `true` when an `initial_value` was passed, that is when the secret's value ended up
    in Terraform's state in the clear.

    It is there so this can be checked in an audit without opening the state: the value
    should be `false` on every production secret.

    `false` means the secret has **no version at all**: no value passed through Terraform, and until somebody populates it `GetSecretValue` returns `ResourceNotFoundException`.
  EOT

  # `nonsensitive` is correct here: the boolean says whether a value was passed, not
  # which one. Marking the output as sensitive would make it useless for exactly the
  # audit it exists for.
  value = nonsensitive(var.initial_value != null)
}
