terraform {
  required_version = ">= 1.11"

  required_providers {
    # This module creates no resources of its own: the provider is used by the
    # wrapped module. The constraint stays declared all the same, because `~> 6.0` is
    # the guarantee the library gives on all of its modules — dropping it here would
    # make that looser on two out of fourteen, with no benefit whatsoever.
    # tflint-ignore: terraform_unused_required_providers
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
