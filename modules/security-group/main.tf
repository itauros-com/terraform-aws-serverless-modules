locals {
  sg_name = var.prefix == null || var.prefix == "" ? var.name : format("%s-%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.sg_name })

  # Exactly one of vpc_id and vpc_name. The check lives in the output's precondition
  # because it involves two distinct variables and the message must be able to say which
  # of the two situations occurred.
  vpc_selector_count = length([for v in [var.vpc_id, var.vpc_name] : v if v != null])

  vpc_id   = var.vpc_id != null ? var.vpc_id : try(data.aws_vpc.by_name[0].id, null)
  vpc_cidr = var.vpc_id != null ? try(data.aws_vpc.by_id[0].cidr_block, null) : try(data.aws_vpc.by_name[0].cidr_block, null)

  # `vpc` as a cidr_blocks value is resolved to the VPC's CIDR: it saves replicating the
  # CIDR in every environment and getting it wrong in one.
  ingress_cidr_rules = [
    for r in var.ingress_cidr_rules : merge(r, {
      cidr_blocks = r.cidr_blocks == "vpc" ? local.vpc_cidr : r.cidr_blocks
    })
  ]

  egress_cidr_rules = [
    for r in var.egress_cidr_rules : merge(r, {
      cidr_blocks = r.cidr_blocks == "vpc" ? local.vpc_cidr : r.cidr_blocks
    })
  ]

  effective_egress_rules = var.allow_all_egress ? ["all-all"] : []

  no_egress_at_all = (
    !var.allow_all_egress &&
    length(var.egress_cidr_rules) == 0 &&
    length(var.egress_source_sg_rules) == 0 &&
    length(var.egress_self_rules) == 0
  )
}

data "aws_vpc" "by_name" {
  count = var.vpc_name != null ? 1 : 0

  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# Only needed to resolve the CIDR when the VPC is given by ID: the security group would
# not need it, but the rules using `vpc` do.
data "aws_vpc" "by_id" {
  count = var.vpc_id != null ? 1 : 0

  id = var.vpc_id
}

module "sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = local.sg_name
  description = coalesce(var.description, format("Security group %s", local.sg_name))
  vpc_id      = local.vpc_id
  tags        = local.tags

  revoke_rules_on_delete = var.revoke_rules_on_delete

  ingress_with_cidr_blocks              = local.ingress_cidr_rules
  ingress_with_source_security_group_id = var.ingress_source_sg_rules
  ingress_with_self                     = var.ingress_self_rules

  egress_rules                         = local.effective_egress_rules
  egress_with_cidr_blocks              = local.egress_cidr_rules
  egress_with_source_security_group_id = var.egress_source_sg_rules
  egress_with_self                     = var.egress_self_rules
}
