mock_provider "aws" {
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

run "no_vpc_given" {
  command = plan

  expect_failures = [output.id]
}

run "vpc_given_twice" {
  command = plan

  variables {
    vpc_id   = "vpc-0123456789abcdef0"
    vpc_name = "acme-prod-vpc"
  }

  expect_failures = [output.id]
}

run "malformed_vpc_id" {
  command = plan

  variables {
    vpc_id = "acme-prod-vpc"
  }

  # Mistaking the name for the ID is the natural error: the message points at
  # `vpc_name`.
  expect_failures = [var.vpc_id]
}

run "no_egress_allowed" {
  command = plan

  variables {
    vpc_id           = "vpc-0123456789abcdef0"
    allow_all_egress = false
  }

  # A security group with no egress rule at all blocks every outbound flow. It is
  # legitimate but almost never intended, and the symptoms are timeouts.
  expect_failures = [output.id]
}

run "prefix_list_rule_without_ids" {
  command = plan

  variables {
    vpc_id = "vpc-0123456789abcdef0"

    egress_prefix_list_rules = [
      { from_port = 443, to_port = 443, prefix_list_ids = [] },
    ]
  }

  # An empty list would reach upstream as an empty string and produce a rule with no
  # destination: allowed by the plan, useless in the account.
  expect_failures = [var.egress_prefix_list_rules]
}

run "prefix_list_rule_with_a_security_group_id" {
  command = plan

  variables {
    vpc_id = "vpc-0123456789abcdef0"

    egress_prefix_list_rules = [
      { from_port = 443, to_port = 443, prefix_list_ids = ["sg-0123456789abcdef0"] },
    ]
  }

  # Confusing the two identifiers is the natural mistake: they are both opaque and both
  # appear in egress rules.
  expect_failures = [var.egress_prefix_list_rules]
}
