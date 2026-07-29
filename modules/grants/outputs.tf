output "policy_json" {
  description = <<-EOT
    The IAM policy document as JSON, or `null` when there are no statements. The
    null is meaningful: attaching a policy with an empty `Statement` is an error on
    the AWS side, so the caller must treat its absence as "no policy to create".
  EOT
  value       = length(local.all_statements) > 0 ? jsonencode(local.policy_document) : null

  # Semantic validation lives here and not in the variables' `validation` blocks
  # because it needs the capability table, which is a local: variable validations
  # can only reference other variables.
  precondition {
    condition = length(local.missing_refs) == 0
    error_message = format(
      "grants references resources that are not in `resources`: %s. Available registry: %s.",
      join(", ", local.missing_refs),
      join(", ", sort(flatten([
        for reg_key, entries in local.registry : [
          for name in keys(entries) : format("%s/%s", [
            for type, meta in local.ref_types : type if meta.registry == reg_key
          ][0], name)
        ]
      ]))),
    )
  }

  precondition {
    condition = length(local.unknown_capabilities) == 0
    error_message = format(
      "Unknown capabilities for the resource type: %s. Valid capabilities: bucket → read, write | table → read, write, scan | topic → publish | queue → publish, consume | secret → read.",
      join(", ", local.unknown_capabilities),
    )
  }

  # No capability produces the "children" scope on services without children, but if
  # the table were extended badly the result would be a statement with an empty
  # `Resource` — which AWS rejects with an opaque error at apply time.
  precondition {
    condition = alltrue([for s in local.all_statements : length(s.resources) > 0])
    error_message = format(
      "Statement without resources (bug in the capability table): %s.",
      join(", ", [for s in local.all_statements : s.sid if length(s.resources) == 0]),
    )
  }
}

output "statements" {
  description = "The statements in structured form, to compose larger policies or to inspect them in tests."
  value       = local.all_statements
}

output "has_policy" {
  description = "`true` when at least one statement exists. Useful as a `count`/`for_each` in the caller."
  value       = length(local.all_statements) > 0
}

output "granted_arns" {
  description = "The ARNs actually referenced by the statements generated from the grants, per resource. Used by the tests and by anyone who needs to check what a policy really grants."
  value       = local.arns
}

output "capability_matrix" {
  description = <<-EOT
    The capability → action table, exposed as data. Terraform does not need it: it is
    for anyone who has to read it or invert it from the outside — documentation,
    audits, conversion tooling — without duplicating it and watching it drift.
  EOT
  value       = local.capabilities
}

output "reference_types" {
  description = "Map of type prefixes to IAM service and child ARN suffix. Used to compose or interpret grant keys from the outside."
  value       = local.ref_types
}
