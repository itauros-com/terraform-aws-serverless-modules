mock_provider "aws" {
  # Mocking the CIDR makes it possible to check that the special `vpc` value is actually
  # resolved, instead of merely checking that the plan passes.
  mock_data "aws_vpc" {
    defaults = {
      id         = "vpc-0123456789abcdef0"
      cidr_block = "10.20.0.0/16"
    }
  }
}

variables {
  prefix = "acme-prod"
  name   = "lambda"
}

run "vpc_by_id" {
  command = plan

  variables {
    vpc_id = "vpc-0123456789abcdef0"
  }

  assert {
    condition     = output.vpc_id == "vpc-0123456789abcdef0"
    error_message = "With vpc_id the VPC must be used as is."
  }
}

run "vpc_by_name" {
  command = plan

  variables {
    vpc_name = "acme-prod-vpc"
  }

  # The name stays stable across environments while the ID changes: that is what allows
  # keeping the environments' configuration identical.
  assert {
    condition     = output.vpc_id == "vpc-0123456789abcdef0"
    error_message = "With vpc_name the VPC's ID must be resolved by the lookup on the Name tag."
  }
}

run "special_vpc_cidr_is_resolved" {
  command = plan

  variables {
    vpc_name = "acme-prod-vpc"

    egress_cidr_rules = [
      { from_port = 5432, to_port = 5432, cidr_blocks = "vpc", description = "PostgreSQL inside the VPC" },
      { from_port = 443, to_port = 443, cidr_blocks = "0.0.0.0/0", description = "Outbound HTTPS" },
    ]
    allow_all_egress = false
  }

  assert {
    condition     = output.vpc_cidr == "10.20.0.0/16"
    error_message = "The VPC's CIDR must be resolved."
  }

  # It saves replicating the CIDR in every environment and getting it wrong in one.
  assert {
    condition     = local.egress_cidr_rules[0].cidr_blocks == "10.20.0.0/16"
    error_message = "The special 'vpc' value must be replaced by the VPC's CIDR."
  }

  assert {
    condition     = local.egress_cidr_rules[1].cidr_blocks == "0.0.0.0/0"
    error_message = "An explicit CIDR must pass through unchanged."
  }
}

run "egress_open_by_default" {
  command = plan

  variables {
    vpc_id = "vpc-0123456789abcdef0"
  }

  # It is what a Lambda in a VPC needs to reach the AWS APIs: without it, its errors are
  # timeouts and not denied permissions.
  assert {
    condition     = var.allow_all_egress == true
    error_message = "Egress must be open by default."
  }
}

run "ingress_rules" {
  command = plan

  variables {
    vpc_name = "acme-prod-vpc"

    ingress_cidr_rules = [
      { from_port = 443, to_port = 443, cidr_blocks = "vpc" },
    ]
    ingress_self_rules = [
      { from_port = 0, to_port = 65535, protocol = "-1", description = "Traffic between resources sharing the group" },
    ]
  }

  assert {
    condition     = local.ingress_cidr_rules[0].cidr_blocks == "10.20.0.0/16"
    error_message = "The special 'vpc' value must be resolved on ingress too."
  }
}

run "prefix_list_rules" {
  command = plan

  variables {
    vpc_id           = "vpc-0123456789abcdef0"
    allow_all_egress = false

    egress_prefix_list_rules = [
      {
        from_port       = 443
        to_port         = 443
        prefix_list_ids = ["pl-6da54004"]
        description     = "HTTPS to S3 via the gateway endpoint"
      },
    ]
  }

  # Upstream wants a comma-separated string, the contract here is a list: the join happens
  # at the edge, so that a typo cannot hide inside a string the module never inspects.
  assert {
    condition     = local.egress_prefix_list_rules[0].prefix_list_ids == "pl-6da54004"
    error_message = "A single prefix list must be passed through as is."
  }

  assert {
    condition     = local.egress_prefix_list_rules[0].from_port == 443
    error_message = "The rule's other fields must survive the conversion."
  }
}

run "several_prefix_lists_in_one_rule" {
  command = plan

  variables {
    vpc_id = "vpc-0123456789abcdef0"

    ingress_prefix_list_rules = [
      { from_port = 443, to_port = 443, prefix_list_ids = ["pl-6da54004", "pl-02cd2c6b"] },
    ]
  }

  assert {
    condition     = local.ingress_prefix_list_rules[0].prefix_list_ids == "pl-6da54004,pl-02cd2c6b"
    error_message = "Several prefix lists in one rule must be joined with a comma, which is what upstream splits on."
  }
}

run "a_prefix_list_rule_is_egress" {
  command = plan

  variables {
    vpc_id           = "vpc-0123456789abcdef0"
    allow_all_egress = false

    egress_prefix_list_rules = [
      { from_port = 443, to_port = 443, prefix_list_ids = ["pl-6da54004"] },
    ]
  }

  # A closed group whose only way out is towards S3 is exactly the intended configuration:
  # it must not trip the "no egress at all" precondition.
  assert {
    condition     = local.no_egress_at_all == false
    error_message = "A prefix list rule is an egress rule and must count as one."
  }
}
