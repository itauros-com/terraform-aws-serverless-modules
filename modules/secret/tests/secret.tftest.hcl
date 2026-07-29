mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  prefix = "acme-prod"
  name   = "database"
}

run "no_value_in_the_state_by_default" {
  command = plan

  # The correct model is to create the secret empty and populate it out of band: any
  # value passed to Terraform ends up in the state in the clear.
  assert {
    condition     = output.value_managed_by_terraform == false
    error_message = "By default the secret's value must not be managed by Terraform."
  }

  assert {
    condition     = var.ignore_value_changes == true
    error_message = "Changes to the value must be ignored by default, otherwise every plan would overwrite the credential in use."
  }
}

run "initial_value_is_reported" {
  command = plan

  variables {
    initial_value = "{}"
  }

  # The output exists so this can be checked in an audit without opening the state.
  assert {
    condition     = output.value_managed_by_terraform == true
    error_message = "Passing an initial_value, the output must report it."
  }
}

run "rotation" {
  command = plan

  variables {
    rotation = {
      enabled                  = true
      lambda_arn               = "arn:aws:lambda:eu-west-1:111122223333:function:acme-prod-rotator"
      automatically_after_days = 30
    }
  }

  assert {
    condition     = var.rotation.enabled == true
    error_message = "Rotation must be configurable."
  }
}

run "immediate_deletion_for_throwaway_environments" {
  command = plan

  variables {
    recovery_window_in_days = 0
  }

  # Without this, a destroy followed by an apply fails: the name stays taken by the
  # scheduled deletion for days.
  assert {
    condition     = var.recovery_window_in_days == 0
    error_message = "The recovery window must be zeroable."
  }
}
