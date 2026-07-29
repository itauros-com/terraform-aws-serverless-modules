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
