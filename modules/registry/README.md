# registry

An ECR repository with immutable tags, scanning on push and lifecycle rules. It wraps
[`terraform-aws-modules/ecr/aws`](https://github.com/terraform-aws-modules/terraform-aws-ecr) `~> 3.0`.

## Usage

```hcl
module "api_image" {
  source = "…//modules/registry"

  prefix = "acme-prod"
  name   = "api"

  # A container Lambda needs a permission on the repository's policy, not only on
  # its own role.
  lambda_read_access_arns = [module.api.arn]
}
```

The final name uses a **slash** and not a dash — `acme-prod/api` — because ECR treats paths as
namespaces.

## Immutable tags

Enabled by default, with declared exceptions (`latest`, `dev-*`).

Without immutability a `docker push` on the same tag changes the deployed code **without any
configuration changing**. There are two consequences: rollback by revert no longer works, because the tag
no longer identifies an image; and Terraform's plan shows nothing, because to Terraform `image_uri` is
identical.

It is the premise of the immutable-tag deploy model: CI builds `…:v1.2.3`, writes it into a versions file,
and promotion between environments becomes a tag change in a PR.

## Two lifecycle rules, not one

| priority | selection | action |
|---|---|---|
| 1 | **untagged** images, older than `untagged_expire_days` (1 by default) | removal |
| 2 | **tagged** images with a prefix in `retained_tag_prefixes`, beyond the last `keep_tagged_images` (30 by default) | removal |

The configuration this library grew out of had a single rule, described as *"Keep last 10 untagged
images"*, which in fact selected `tagStatus = "tagged"` with the `v` prefix. The result was the opposite of
the description: the untagged images were never removed and were billed indefinitely, while the releases
were deleted beyond the tenth.

Untagged images are the ones replaced by a later push on the same tag: they are referenced by nothing and
are billed as long as they stay.

`keep_tagged_images` must be kept high enough to cover the rollback window: if you keep 10 images and
release 20 a day, rolling back to yesterday is not possible. The default is 30.

## Notes

- `scan_on_push` is enabled by default: basic scanning is free, and the only alternative is not knowing.
- `lambda_read_access_arns` is not a detail: without that permission **on the repository's policy** the
  creation of a container Lambda fails with an error that talks about an image not found, and the real
  cause appears nowhere.
- `force_delete` is `false` by default: a deleted repository takes the running images with it.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_ecr"></a> [ecr](#module\_ecr) | terraform-aws-modules/ecr/aws | ~> 3.0 |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | The repository's name. If `prefix` is set the final name is `<prefix>/<name>` — a slash instead of a dash because ECR uses paths as namespaces. | `string` | n/a | yes |
| <a name="input_force_delete"></a> [force\_delete](#input\_force\_delete) | Allows deleting the repository even if it contains images. Keep it false on anything production needs. | `bool` | `false` | no |
| <a name="input_immutable_tags"></a> [immutable\_tags](#input\_immutable\_tags) | Immutable tags. **Enabled by default**: without them, a `docker push` on the same tag<br/>changes the deployed code without any configuration changing, and rollback by revert<br/>no longer works because the tag no longer identifies an image.<br/><br/>`mutable_tag_patterns` lists the exceptions, typically the moving tags of development<br/>environments. | `bool` | `true` | no |
| <a name="input_keep_tagged_images"></a> [keep\_tagged\_images](#input\_keep\_tagged\_images) | How many tagged images to keep for each prefix in `retained_tag_prefixes`. The oldest<br/>ones beyond this number are removed.<br/><br/>It must be kept high enough to cover the rollback window: if you keep 10 images and<br/>release 20 a day, rolling back to yesterday is not possible. | `number` | `30` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | CMK to encrypt the images. Null uses the AES256 encryption managed by ECR. | `string` | `null` | no |
| <a name="input_lambda_read_access_arns"></a> [lambda\_read\_access\_arns](#input\_lambda\_read\_access\_arns) | Lambda functions authorized to read the images.<br/><br/>It is needed because a container-based Lambda needs a permission **on the repository's<br/>policy**, not only on its own role: without it, the function's creation fails with an<br/>error that talks about an image not found. | `list(string)` | `[]` | no |
| <a name="input_mutable_tag_patterns"></a> [mutable\_tag\_patterns](#input\_mutable\_tag\_patterns) | Tag patterns excluded from immutability, wildcard style. At most 5, as AWS requires. | `list(string)` | <pre>[<br/>  "latest",<br/>  "dev-*"<br/>]</pre> | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, used as the repository's namespace. | `string` | `null` | no |
| <a name="input_read_access_arns"></a> [read\_access\_arns](#input\_read\_access\_arns) | Principals authorized to read from the repository, for example the roles of another account. | `list(string)` | `[]` | no |
| <a name="input_retained_tag_prefixes"></a> [retained\_tag\_prefixes](#input\_retained\_tag\_prefixes) | Prefixes of the tags subject to the retention rule. Images with other tags are never removed automatically. | `list(string)` | <pre>[<br/>  "v"<br/>]</pre> | no |
| <a name="input_scan_on_push"></a> [scan\_on\_push](#input\_scan\_on\_push) | Vulnerability scanning on push. Enabled by default: it is free in basic mode and the only alternative is not knowing. | `bool` | `true` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |
| <a name="input_untagged_expire_days"></a> [untagged\_expire\_days](#input\_untagged\_expire\_days) | Days after which an untagged image is removed.<br/><br/>Untagged images are the ones replaced by a later push on the same tag: they are<br/>referenced by nothing and are billed as long as they stay. | `number` | `1` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_arn"></a> [arn](#output\_arn) | The repository's ARN. |
| <a name="output_lifecycle_rules"></a> [lifecycle\_rules](#output\_lifecycle\_rules) | The generated lifecycle rules, for inspection.<br/><br/>There are two of them and they are distinct — removing the untagged ones and keeping<br/>the tagged ones — because merging the two into a single rule is how a policy ends up<br/>describing a behaviour different from the one it has. |
| <a name="output_name"></a> [name](#output\_name) | The repository's name, already carrying the prefix namespace. |
| <a name="output_registry_id"></a> [registry\_id](#output\_registry\_id) | The registry's ID, that is the account that owns it. |
| <a name="output_tag_mutability"></a> [tag\_mutability](#output\_tag\_mutability) | The tag mutability mode actually applied. Derived from the inputs, hence known at plan time. |
| <a name="output_url"></a> [url](#output\_url) | The repository's URL. It is the base of the `image_uri`s: `<url>:<tag>`. |
<!-- END_TF_DOCS -->
