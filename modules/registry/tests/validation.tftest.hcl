mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  prefix = "acme-prod"
  name   = "api"
}

run "too_many_exclusion_patterns" {
  command = plan

  variables {
    mutable_tag_patterns = ["a", "b", "c", "d", "e", "f"]
  }

  expect_failures = [var.mutable_tag_patterns]
}

run "no_prefix_to_retain" {
  command = plan

  variables {
    retained_tag_prefixes = []
  }

  # A retention rule with no prefixes selects nothing: it looks configured and removes
  # nothing.
  expect_failures = [var.retained_tag_prefixes]
}

run "retention_out_of_range" {
  command = plan

  variables {
    keep_tagged_images = 0
  }

  expect_failures = [var.keep_tagged_images]
}
