terraform {
  required_version = ">= 1.11"

  required_providers {
    # The floor of modules/http-api, which this module always calls.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28, < 7.0"
    }
  }
}
