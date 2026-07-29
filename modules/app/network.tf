module "security_groups" {
  source = "../security-group"

  for_each = var.security_groups

  prefix      = var.prefix
  name        = each.key
  description = each.value.description
  tags        = merge(local.tags, each.value.tags)

  vpc_id   = each.value.vpc_id
  vpc_name = each.value.vpc_name

  ingress_cidr_rules      = each.value.ingress_cidr_rules
  ingress_source_sg_rules = each.value.ingress_source_sg_rules
  ingress_self_rules      = each.value.ingress_self_rules
  egress_cidr_rules       = each.value.egress_cidr_rules
  egress_source_sg_rules  = each.value.egress_source_sg_rules
  egress_self_rules       = each.value.egress_self_rules
  allow_all_egress        = each.value.allow_all_egress
}
