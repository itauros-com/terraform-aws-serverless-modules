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

run "namespace_with_a_slash" {
  command = plan

  # ECR uses paths as namespaces: `acme-prod/api` and not `acme-prod-api`.
  assert {
    condition     = local.repository_name == "acme-prod/api"
    error_message = "The name must join prefix and name with a slash."
  }
}

run "immutable_tags_with_exceptions_by_default" {
  command = plan

  # Without immutability a push on the same tag changes the deployed code without any
  # configuration changing, and rollback by revert no longer works.
  assert {
    condition     = output.tag_mutability == "IMMUTABLE_WITH_EXCLUSION"
    error_message = "The tags must be immutable with the declared exceptions."
  }
}

run "full_immutability_without_exceptions" {
  command = plan

  variables {
    mutable_tag_patterns = []
  }

  assert {
    condition     = output.tag_mutability == "IMMUTABLE"
    error_message = "Without exclusion patterns the mode must be IMMUTABLE."
  }
}

run "two_distinct_lifecycle_rules" {
  command = plan

  # The previous configuration had a single rule described as "keep last 10 untagged"
  # which in fact selected the tagged ones with the "v" prefix: the untagged images were
  # never removed and the releases were deleted.
  assert {
    condition     = length(output.lifecycle_rules) == 2
    error_message = "There must be two distinct rules: removing the untagged and keeping the tagged."
  }

  assert {
    condition     = output.lifecycle_rules[0].selection.tagStatus == "untagged"
    error_message = "The first rule must act on untagged images."
  }

  assert {
    condition     = output.lifecycle_rules[0].selection.countType == "sinceImagePushed"
    error_message = "The untagged ones are removed by age, not by count."
  }

  assert {
    condition     = output.lifecycle_rules[1].selection.tagStatus == "tagged"
    error_message = "The second rule must act on tagged images."
  }

  assert {
    condition     = output.lifecycle_rules[1].selection.countNumber == 30
    error_message = "The number of retained images must be the configured one."
  }

  assert {
    condition     = output.lifecycle_rules[1].selection.tagPrefixList == tolist(["v"])
    error_message = "The retention must apply to the declared prefixes."
  }
}

run "retention_is_configurable" {
  command = plan

  variables {
    keep_tagged_images    = 100
    retained_tag_prefixes = ["v", "release-"]
    untagged_expire_days  = 7
  }

  assert {
    condition     = output.lifecycle_rules[0].selection.countNumber == 7
    error_message = "The untagged expiry days must be configurable."
  }

  assert {
    condition     = output.lifecycle_rules[1].selection.tagPrefixList == tolist(["v", "release-"])
    error_message = "The retained prefixes must be configurable."
  }
}
