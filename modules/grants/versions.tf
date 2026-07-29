terraform {
  required_version = ">= 1.11"
}

# No required_providers: this module creates no resources and reads no data
# sources. It is pure computation over variables, so it is tested without
# credentials and without mocks. This is deliberate — see the README.
