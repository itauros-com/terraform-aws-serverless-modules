locals {
  repository_name = var.prefix == null || var.prefix == "" ? var.name : format("%s/%s", var.prefix, var.name)

  tags = merge(var.tags, { Name = local.repository_name })

  tag_mutability = var.immutable_tags ? (
    length(var.mutable_tag_patterns) > 0 ? "IMMUTABLE_WITH_EXCLUSION" : "IMMUTABLE"
  ) : "MUTABLE"

  # Two distinct rules, not one.
  #
  # The configuration this library grew out of had a single rule described as "keep last
  # 10 untagged images" which in fact selected the *tagged* images with the "v" prefix:
  # the untagged ones were never removed and were billed indefinitely, while the releases
  # were deleted beyond the tenth. The description and the behaviour said different
  # things.
  lifecycle_policy = {
    rules = [
      {
        rulePriority = 1
        description  = format("Removes untagged images after %d days", var.untagged_expire_days)
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expire_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = format("Keeps the last %d images with prefix %s", var.keep_tagged_images, join(", ", var.retained_tag_prefixes))
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = var.retained_tag_prefixes
          countType     = "imageCountMoreThan"
          countNumber   = var.keep_tagged_images
        }
        action = { type = "expire" }
      },
    ]
  }
}

module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 3.0"

  repository_name = local.repository_name
  tags            = local.tags

  repository_image_tag_mutability = local.tag_mutability

  repository_image_tag_mutability_exclusion_filter = var.immutable_tags ? [
    for p in var.mutable_tag_patterns : {
      filter      = p
      filter_type = "WILDCARD"
    }
  ] : []

  repository_image_scan_on_push = var.scan_on_push
  repository_encryption_type    = var.kms_key_arn != null ? "KMS" : "AES256"
  repository_kms_key            = var.kms_key_arn
  repository_force_delete       = var.force_delete

  repository_read_access_arns        = var.read_access_arns
  repository_lambda_read_access_arns = var.lambda_read_access_arns

  repository_lifecycle_policy = jsonencode(local.lifecycle_policy)
}
