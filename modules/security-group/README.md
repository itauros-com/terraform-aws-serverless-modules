# security-group

A security group with the VPC identifiable by name and the VPC's CIDR resolvable inside the rules.
It wraps [`terraform-aws-modules/security-group/aws`](https://github.com/terraform-aws-modules/terraform-aws-security-group)
`~> 5.0`.

## Usage

```hcl
module "lambda_sg" {
  source = "…//modules/security-group"

  prefix   = "acme-prod"
  name     = "lambda"
  vpc_name = "acme-prod-vpc"   # resolved to an ID through the Name tag

  egress_cidr_rules = [
    { from_port = 5432, to_port = 5432, cidr_blocks = "vpc", description = "PostgreSQL inside the VPC" },
    { from_port = 443, to_port = 443, cidr_blocks = "0.0.0.0/0", description = "AWS APIs" },
  ]
  allow_all_egress = false
}
```

And in the function:

```hcl
module "api" {
  source = "…//modules/function"

  vpc = {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [module.lambda_sg.id]
  }
}
```

## The VPC by name, the CIDR by reference

`vpc_name` resolves the VPC from its `Name` tag instead of requiring its ID. It is what you need when the
VPC is created elsewhere and its ID changes between environments: the name stays stable and the
environments' configuration stays identical. `vpc_id` remains available for the cases where you already
have the ID; stating **exactly one** of them is checked.

In the rules, `cidr_blocks = "vpc"` is replaced by the CIDR of the security group's VPC. It saves
replicating the CIDR in every environment file — and getting it wrong in just one, which is how a rule
ends up opening more than it should.

## Egress

`allow_all_egress` is `true` by default. It is not the better configuration, it is the one that works: a
Lambda in a VPC with no egress does not even reach the AWS APIs, and its errors are **timeouts**, not
denied permissions — so the diagnosis is slow.

The better configuration is to disable it and open only what is needed, together with VPC endpoints for
the AWS services: you also save the NAT gateway. But it is a choice to be made, not a default that breaks
things.

If you set it to `false` **without** declaring any egress rule, the module stops the plan: a security
group blocking every outbound flow is legitimate but almost never intended.

## Notes

- AWS does not allow changing a security group's `description` after creation: changing it means
  recreating it, and therefore detaching and reattaching everything that uses it.
- `revoke_rules_on_delete` is `true` by default: it avoids being blocked on deletion when two groups
  reference each other.
- The module creates neither VPCs nor subnets: it looks them up. Creating network inside an application
  module is how you end up with the production VPC in the application's state.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_sg"></a> [sg](#module\_sg) | terraform-aws-modules/security-group/aws | ~> 5.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_vpc.by_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |
| [aws_vpc.by_name](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | The security group's name. If `prefix` is set the final name is `<prefix>-<name>`. | `string` | n/a | yes |
| <a name="input_allow_all_egress"></a> [allow\_all\_egress](#input\_allow\_all\_egress) | Allows all outbound traffic. **Enabled by default**, because it is what a Lambda in a<br/>VPC needs to reach the AWS APIs and without which nothing works — and because it is<br/>the behaviour of AWS's default security group.<br/><br/>The better configuration is to disable it and open only what is needed, together with<br/>VPC endpoints for the AWS services: you also save the NAT gateway. But it is a choice<br/>to be made, not a default that breaks things.<br/><br/>Setting it to `false` without declaring any egress rule makes the security group block<br/>every outbound flow: the module reports that. | `bool` | `true` | no |
| <a name="input_description"></a> [description](#input\_description) | The security group's description. AWS does not allow changing it after creation. | `string` | `null` | no |
| <a name="input_egress_cidr_rules"></a> [egress\_cidr\_rules](#input\_egress\_cidr\_rules) | Egress rules towards CIDR blocks. `cidr_blocks` accepts the special value `vpc`, as on ingress. | <pre>list(object({<br/>    from_port   = number<br/>    to_port     = number<br/>    protocol    = optional(string, "tcp")<br/>    cidr_blocks = string<br/>    description = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_egress_self_rules"></a> [egress\_self\_rules](#input\_egress\_self\_rules) | Egress rules towards the security group itself. | <pre>list(object({<br/>    from_port   = number<br/>    to_port     = number<br/>    protocol    = optional(string, "tcp")<br/>    description = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_egress_source_sg_rules"></a> [egress\_source\_sg\_rules](#input\_egress\_source\_sg\_rules) | Egress rules towards another security group. | <pre>list(object({<br/>    from_port                = number<br/>    to_port                  = number<br/>    protocol                 = optional(string, "tcp")<br/>    source_security_group_id = string<br/>    description              = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_ingress_cidr_rules"></a> [ingress\_cidr\_rules](#input\_ingress\_cidr\_rules) | Ingress rules from CIDR blocks.<br/><br/>`cidr_blocks` also accepts the special value `vpc`, which is resolved to the CIDR of<br/>the security group's VPC: it saves replicating the CIDR in every environment and<br/>getting it wrong in one. | <pre>list(object({<br/>    from_port   = number<br/>    to_port     = number<br/>    protocol    = optional(string, "tcp")<br/>    cidr_blocks = string<br/>    description = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_ingress_self_rules"></a> [ingress\_self\_rules](#input\_ingress\_self\_rules) | Ingress rules from the security group itself, for traffic between resources that share it. | <pre>list(object({<br/>    from_port   = number<br/>    to_port     = number<br/>    protocol    = optional(string, "tcp")<br/>    description = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_ingress_source_sg_rules"></a> [ingress\_source\_sg\_rules](#input\_ingress\_source\_sg\_rules) | Ingress rules from another security group. | <pre>list(object({<br/>    from_port                = number<br/>    to_port                  = number<br/>    protocol                 = optional(string, "tcp")<br/>    source_security_group_id = string<br/>    description              = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Naming prefix, typically `<project>-<environment>`. | `string` | `null` | no |
| <a name="input_revoke_rules_on_delete"></a> [revoke\_rules\_on\_delete](#input\_revoke\_rules\_on\_delete) | Revoke all the rules before deleting the security group. Avoids being blocked by cyclic dependencies between groups. | `bool` | `true` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | The VPC's ID. An alternative to `vpc_name`: state exactly one of them. | `string` | `null` | no |
| <a name="input_vpc_name"></a> [vpc\_name](#input\_vpc\_name) | Value of the VPC's `Name` tag, resolved to an ID with a lookup. An alternative to<br/>`vpc_id`: state exactly one of them.<br/><br/>It is what you need when the VPC is created elsewhere and its ID changes between<br/>environments: the name stays stable and the environments' configuration stays<br/>identical. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_arn"></a> [arn](#output\_arn) | The security group's ARN. |
| <a name="output_id"></a> [id](#output\_id) | The security group's ID. It is what you pass to modules/function's `vpc.security_group_ids`. |
| <a name="output_name"></a> [name](#output\_name) | The security group's name, already prefixed. |
| <a name="output_vpc_cidr"></a> [vpc\_cidr](#output\_vpc\_cidr) | The VPC's CIDR, the one used to resolve the special `vpc` value in the rules. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | The security group's VPC ID, resolved from the Name tag when `vpc_name` was given. |
<!-- END_TF_DOCS -->
