plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Reusable modules declare no provider: required_providers lives in versions.tf
# and the providers themselves come from the caller.
rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

# Every variable and every output must have a description: they are the module's
# public contract and they end up in the generated README.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Disabled: the examples use local modules with a relative source.
rule "terraform_module_pinned_source" {
  enabled = false
}
