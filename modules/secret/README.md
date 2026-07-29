# secret

A secret in Secrets Manager, created empty and populated outside Terraform. It wraps
[`terraform-aws-modules/secrets-manager/aws`](https://github.com/terraform-aws-modules/terraform-aws-secrets-manager)
`~> 2.0`.

## Usage

```hcl
module "database" {
  source = "…//modules/secret"

  prefix      = "acme-prod"
  name        = "database"
  description = "PostgreSQL connection string. Populated by the bootstrap, rotated by hand."
}
```

The secret is born **empty** — no version at all. You populate it afterwards, once:

```bash
aws secretsmanager put-secret-value \
  --secret-id acme-prod-database \
  --secret-string "$(read -rs; echo "$REPLY")"
```

And in the consumer:

```hcl
module "api" {
  source = "…//modules/function"

  resources = { secrets = { database = module.database.registry_entry } }
  grants    = { "secret/database" = ["read"] }
  env_from  = { DATABASE_SECRET = { secret = "database" } }
}
```

Note that `env_from` injects the secret's **name**, not its value: the function reads it at runtime with
`GetSecretValue`. A value read by Terraform and passed as an environment variable would be visible in the
Lambda's configuration to anyone with `lambda:GetFunction`.

## The value does not go through Terraform

`initial_value` exists but must be avoided: **any value passed to Terraform ends up in the state in the
clear**, and the state is readable by anyone with access to the bucket. In the wiring this library grew
out of, the default was `secret_string = "{}"` and the tfvars lived in the same bucket as the state.

Until somebody populates it, `GetSecretValue` returns `ResourceNotFoundException`. That is
the intended failure: it names the problem. A placeholder value would be handed to the
application, which would fail further downstream against whatever it authenticates to — an
error pointing somewhere else entirely.

This is also why the module writes these resources natively instead of wrapping
`terraform-aws-modules/secrets-manager`: that module always creates exactly one secret
version, and a version with no value is rejected by AWS. Creating an empty secret was not
expressible through it.

`ignore_value_changes` is `true` by default: without it, every plan would try to bring the secret back to
the content Terraform knows about, **wiping out the credential in use**.

The `value_managed_by_terraform` output tells you whether a value was passed. It is there to check that in
an audit without opening the state: on every production secret it should be `false`.

## Opinionated defaults

| | module default | AWS default | why |
|---|---|---|---|
| value | **none, no version** | none | see above |
| `ignore_value_changes` | **true** | — | stops a plan from wiping out the credential in use |
| `block_public_policy` | **true** | false | rejects a resource policy that would grant public access |
| `recovery_window_in_days` | 30 | 30 | |

## Throwaway environments

`recovery_window_in_days = 0` deletes immediately. Without it, a `destroy` followed by an `apply` fails:
the name stays taken by the scheduled deletion for days, and the error (`already scheduled for deletion`)
does not suggest the solution.

## Rotation

```hcl
rotation = {
  enabled                  = true
  lambda_arn               = module.rotator.arn
  automatically_after_days = 30
}
```

The rotation function must implement the four steps AWS expects — `createSecret`, `setSecret`,
`testSecret`, `finishSecret`. Configuring rotation with a non-conforming function leaves the secret in a
state where rotation fails on every cycle, with nothing signalling it beyond Secrets Manager's metrics.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_secretsmanager_secret.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_policy) | resource |
| [aws_secretsmanager_secret_rotation.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_rotation) | resource |
| [aws_secretsmanager_secret_version.frozen](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_secretsmanager_secret_version.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_iam_policy_document.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | The secret's name. If `prefix` is set the final name is `<prefix>-<name>`. | `string` | n/a | yes |
| <a name="input_description"></a> [description](#input\_description) | The secret's description. It is worth writing what it contains and who populates it, because the value is not readable from the code. | `string` | `null` | no |
| <a name="input_ignore_value_changes"></a> [ignore\_value\_changes](#input\_ignore\_value\_changes) | Ignore changes to the secret's value. **Enabled by default**: the real value is<br/>written by somebody else, and without this option every plan would try to bring it<br/>back to the content Terraform knows about, wiping out the credential in use. | `bool` | `true` | no |
| <a name="input_initial_value"></a> [initial\_value](#input\_initial\_value) | Initial value, **to be avoided**.<br/><br/>Any value passed here ends up in Terraform's state in the clear, and the state is<br/>readable by anyone with access to the bucket. The correct model is to leave this null<br/>and populate the secret out of band — from the console, from the CLI or from a<br/>bootstrap process — letting `ignore_value_changes` stop Terraform from bringing it<br/>back.<br/><br/>Left null, no version is created at all: the secret exists and is empty, and<br/>`GetSecretValue` returns `ResourceNotFoundException` until somebody populates it. That<br/>is deliberate — it names the problem, where a placeholder value would be handed to the<br/>application and fail further downstream.<br/><br/>If you use it anyway, for example for a placeholder JSON structure in a development<br/>environment, know that it is a conscious choice and not a default. | `string` | `null` | no |
| <a name="input_kms_key_id"></a> [kms\_key\_id](#input\_kms\_key\_id) | The CMK to encrypt the secret with. Null uses the AWS-managed key for Secrets Manager. | `string` | `null` | no |
| <a name="input_policy_statements"></a> [policy\_statements](#input\_policy\_statements) | Statements for the secret's resource policy, for example for a cross-account read. In the format the upstream module accepts. | `map(any)` | `{}` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, typically `<project>-<environment>`. | `string` | `null` | no |
| <a name="input_recovery_window_in_days"></a> [recovery\_window\_in\_days](#input\_recovery\_window\_in\_days) | Recovery window after deletion. The default of 30 days is AWS's.<br/><br/>`0` deletes immediately and allows recreating a secret with the same name right<br/>afterwards: this is needed in throwaway environments, where otherwise a `destroy`<br/>followed by an `apply` fails because the name is still scheduled for deletion. | `number` | `30` | no |
| <a name="input_rotation"></a> [rotation](#input\_rotation) | Automatic rotation through a Lambda.<br/><br/>The rotation function must implement the four steps AWS expects (`createSecret`,<br/>`setSecret`, `testSecret`, `finishSecret`): configuring rotation without a conforming<br/>function leaves the secret in a state where rotation fails silently on every cycle. | <pre>object({<br/>    enabled                  = optional(bool, false)<br/>    lambda_arn               = optional(string)<br/>    automatically_after_days = optional(number)<br/>    schedule_expression      = optional(string)<br/>    duration                 = optional(string)<br/>    rotate_immediately       = optional(bool, false)<br/>  })</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_arn"></a> [arn](#output\_arn) | The secret's ARN. |
| <a name="output_id"></a> [id](#output\_id) | The secret's ID, which for Secrets Manager **is the ARN** and not the name. Kept for symmetry with the other modules; prefer `arn` or `name`, which say what they are. |
| <a name="output_name"></a> [name](#output\_name) | The secret's name, already prefixed. It is what you pass to `GetSecretValue` — which also accepts the ARN, so both work. |
| <a name="output_registry_entry"></a> [registry\_entry](#output\_registry\_entry) | The entry to put into the consumers' `resources` registry, already in the expected<br/>shape, CMK included.<br/><br/>    resources = { secrets = { database = module.database.registry\_entry } } |
| <a name="output_value_managed_by_terraform"></a> [value\_managed\_by\_terraform](#output\_value\_managed\_by\_terraform) | `true` when an `initial_value` was passed, that is when the secret's value ended up<br/>in Terraform's state in the clear.<br/><br/>It is there so this can be checked in an audit without opening the state: the value<br/>should be `false` on every production secret.<br/><br/>`false` means the secret has **no version at all**: no value passed through Terraform, and until somebody populates it `GetSecretValue` returns `ResourceNotFoundException`. |
<!-- END_TF_DOCS -->
