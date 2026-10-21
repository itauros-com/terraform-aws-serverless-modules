terraform {
  required_version = ">= 1.11"

  required_providers {
    # apigateway-v2 6.x requires 6.28. Declared here too, so that a caller whose lock file is
    # older reads the reason in `init` rather than in the upstream module's constraint.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28, < 7.0"
    }
  }
}
