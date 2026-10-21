mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_data "aws_subnet" {
    defaults = {
      id                = "subnet-0123456789abcdef0"
      vpc_id            = "vpc-0123456789abcdef0"
      availability_zone = "eu-west-1a"
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      id         = "vpc-0123456789abcdef0"
      cidr_block = "10.20.0.0/16"
    }
  }
}

variables {
  prefix = "acme-prod"
  name   = "reconcile"

  resources = {
    buckets = {
      glue-scripts = { arn = "arn:aws:s3:::acme-prod-glue-scripts", name = "acme-prod-glue-scripts" }
      # Deliberately without `name`: the resource exists but cannot be used as a location.
      unnamed = { arn = "arn:aws:s3:::acme-prod-unnamed" }
    }
    secrets = {
      database = { arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:acme-prod-database-AbCdEf", name = "acme-prod-database" }
    }
  }

  script = { bucket = "glue-scripts", key = "scripts/reconcile_etl_job.py" }
}

# ------------------------------------------------------------------------------
# Code
# ------------------------------------------------------------------------------

run "script_in_a_nonexistent_bucket" {
  command = plan

  variables {
    script = { bucket = "glue-scirpts", key = "scripts/reconcile_etl_job.py" }
  }

  expect_failures = [var.script]
}

run "script_key_with_a_leading_slash" {
  command = plan

  variables {
    script = { bucket = "glue-scripts", key = "/scripts/reconcile_etl_job.py" }
  }

  # `s3://bucket//scripts/…` is a different object: Glue would fail at start, not at plan.
  expect_failures = [var.script]
}

run "script_bucket_without_a_name" {
  command = plan

  variables {
    script = { bucket = "unnamed", key = "scripts/reconcile_etl_job.py" }
  }

  expect_failures = [aws_glue_job.this]
}

run "temp_dir_in_a_nonexistent_bucket" {
  command = plan

  variables {
    temp_dir = { bucket = "nope" }
  }

  expect_failures = [var.temp_dir]
}

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------

run "argument_without_dashes" {
  command = plan

  variables {
    args = { ENV = "prod" }
  }

  # Glue passes it to the script, and `getResolvedOptions` does not find it.
  expect_failures = [var.args]
}

run "argument_the_module_manages" {
  command = plan

  variables {
    args = { "--TempDir" = "s3://somewhere-else/" }
  }

  expect_failures = [var.args]
}

run "args_from_towards_a_nonexistent_resource" {
  command = plan

  variables {
    args_from = { "--SECRET_NAME" = { secret = "databse" } }
  }

  # The whole point of resolving by key: a typo stops the plan, instead of reaching the
  # script as a literal string and failing at run time.
  expect_failures = [var.args_from]
}

run "args_from_with_two_types" {
  command = plan

  variables {
    args_from = { "--TARGET" = { bucket = "glue-scripts", secret = "database" } }
  }

  expect_failures = [var.args_from]
}

run "same_argument_literal_and_referenced" {
  command = plan

  variables {
    args      = { "--SECRET_NAME" = "acme-prod-database" }
    args_from = { "--SECRET_NAME" = { secret = "database" } }
  }

  expect_failures = [var.args_from]
}

run "args_from_towards_an_attribute_that_is_null" {
  command = plan

  variables {
    args_from = { "--SECRET_URL" = { secret = "database", attr = "url" } }
  }

  expect_failures = [aws_glue_job.this]
}

# ------------------------------------------------------------------------------
# Capacity
# ------------------------------------------------------------------------------

run "workers_on_a_python_shell_job" {
  command = plan

  variables {
    command     = "pythonshell"
    worker_type = "G.1X"
  }

  expect_failures = [var.worker_type]
}

run "dpus_on_a_spark_job" {
  command = plan

  variables {
    max_capacity = 1
  }

  expect_failures = [var.max_capacity]
}

run "a_single_worker" {
  command = plan

  variables {
    number_of_workers = 1
  }

  expect_failures = [var.number_of_workers]
}

run "streaming_job" {
  command = plan

  variables {
    command = "gluestreaming"
  }

  expect_failures = [var.command]
}

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------

run "jdbc_secret_not_granted" {
  command = plan

  variables {
    network = {
      subnet_id = "subnet-0123456789abcdef0"
      jdbc      = { url = "jdbc:postgresql://db.internal:5432/app", secret = "database" }
    }
  }

  # The connection and the secret both exist, and the run fails at start with an
  # AccessDenied on Secrets Manager.
  expect_failures = [var.network]
}

run "jdbc_secret_not_in_the_registry" {
  command = plan

  variables {
    network = {
      subnet_id = "subnet-0123456789abcdef0"
      jdbc      = { url = "jdbc:postgresql://db.internal:5432/app", secret = "nope" }
    }
  }

  expect_failures = [var.network]
}

# ------------------------------------------------------------------------------
# Observability
# ------------------------------------------------------------------------------

run "unknown_run_state" {
  command = plan

  variables {
    observability = { alarms = { states = ["FAILURE"] } }
  }

  # A pattern on a state that does not exist matches nothing, and nothing ever notifies.
  expect_failures = [var.observability]
}
