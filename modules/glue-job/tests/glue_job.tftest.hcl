mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  # The connection takes its availability zone from the subnet and the security group its
  # VPC: with generated values neither would be assertable.
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

  # The role's ARN reaches the job; the job's ARN reaches `registry_entry`. Generated, they
  # would not have the shape the provider validates.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/acme-prod-reconcile-glue" }
  }

  mock_resource "aws_glue_job" {
    defaults = { arn = "arn:aws:glue:eu-west-1:111122223333:job/acme-prod-reconcile" }
  }
}

# The shape of the job this module was written for: a Spark ETL on Glue 4.0, two G.1X
# workers, one hour, reaching a PostgreSQL database inside the VPC and reading from S3,
# DynamoDB and Secrets Manager, with the resource names passed as arguments.
variables {
  prefix = "acme-prod"
  name   = "reconcile"

  resources = {
    buckets = {
      glue-scripts = { arn = "arn:aws:s3:::acme-prod-glue-scripts", name = "acme-prod-glue-scripts" }
      glue-temp    = { arn = "arn:aws:s3:::acme-prod-glue-temp", name = "acme-prod-glue-temp" }
      documents    = { arn = "arn:aws:s3:::acme-prod-documents", name = "acme-prod-documents" }
    }
    tables = {
      attributes = { arn = "arn:aws:dynamodb:eu-west-1:111122223333:table/acme-prod-attributes", name = "acme-prod-attributes" }
    }
    secrets = {
      database = { arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:acme-prod-database-AbCdEf", name = "acme-prod-database" }
    }
  }

  script       = { bucket = "glue-scripts", key = "scripts/reconcile_etl_job.py" }
  temp_dir     = { bucket = "glue-temp" }
  glue_version = "4.0"

  args = {
    "--ENV"                 = "prod"
    "--job-bookmark-option" = "job-bookmark-disable"
  }

  args_from = {
    "--target_bucket" = { bucket = "documents" }
    "--SECRET_NAME"   = { secret = "database" }
    "--DYNAMO_TABLE"  = { table = "attributes" }
  }

  grants = {
    "bucket/documents" = ["read", "write"]
    "table/attributes" = ["read"]
    "secret/database"  = ["read"]
  }

  observability = {
    alarms = { actions = ["arn:aws:sns:eu-west-1:111122223333:acme-prod-alarms"] }
  }
}

run "naming_with_a_prefix" {
  command = plan

  assert {
    condition     = aws_glue_job.this.name == "acme-prod-reconcile"
    error_message = "The final name must be <prefix>-<name>."
  }

  assert {
    condition     = aws_iam_role.this.name == "acme-prod-reconcile-glue"
    error_message = "The role must take its name from the job."
  }
}

run "spark_defaults" {
  command = plan

  assert {
    condition     = aws_glue_job.this.command[0].name == "glueetl" && aws_glue_job.this.command[0].python_version == "3"
    error_message = "A job is a Spark ETL on Python 3 unless told otherwise."
  }

  assert {
    condition     = aws_glue_job.this.worker_type == "G.1X" && aws_glue_job.this.number_of_workers == 2
    error_message = "A Spark job must default to two G.1X workers, the smallest Glue accepts."
  }

  # Glue's own default is 2880 minutes: two days of billing before anybody is told.
  assert {
    condition     = aws_glue_job.this.timeout == 60
    error_message = "The timeout must default to one hour, not Glue's two days."
  }

  assert {
    condition     = aws_glue_job.this.max_retries == 0
    error_message = "A run must not be retried by default: an ETL that is not idempotent must not run twice by accident."
  }

  assert {
    condition     = aws_glue_job.this.glue_version == "4.0"
    error_message = "An explicit Glue version must reach the job."
  }
}

run "script_location_resolved_from_the_registry" {
  command = plan

  assert {
    condition     = aws_glue_job.this.command[0].script_location == "s3://acme-prod-glue-scripts/scripts/reconcile_etl_job.py"
    error_message = "The script's location must be built from the bucket's name in the registry and the key."
  }
}

run "args_from_resolves_like_env_from" {
  command = plan

  assert {
    condition     = output.default_arguments["--target_bucket"] == "acme-prod-documents"
    error_message = "A bucket reference must resolve to the bucket's name."
  }

  assert {
    condition     = output.default_arguments["--SECRET_NAME"] == "acme-prod-database"
    error_message = "A secret reference must resolve to the secret's name."
  }

  assert {
    condition     = output.default_arguments["--DYNAMO_TABLE"] == "acme-prod-attributes"
    error_message = "A table reference must resolve to the table's name."
  }

  assert {
    condition     = output.default_arguments["--ENV"] == "prod"
    error_message = "Literal arguments must reach the job unchanged."
  }
}

run "managed_arguments" {
  command = plan

  # Per job, under its name: two jobs sharing the temp bucket must not read each other's
  # leftovers.
  assert {
    condition     = output.default_arguments["--TempDir"] == "s3://acme-prod-glue-temp/acme-prod-reconcile/"
    error_message = "The temp dir must default to a prefix named after the job."
  }

  assert {
    condition     = output.default_arguments["--continuous-log-logGroup"] == "/aws-glue/jobs/acme-prod-reconcile"
    error_message = "Continuous logging must write to the job's own log group."
  }

  assert {
    condition = alltrue([
      for k in ["--enable-metrics", "--enable-continuous-cloudwatch-log", "--enable-job-insights"] : output.default_arguments[k] == "true"
    ])
    error_message = "Metrics, continuous logging and job insights must be on by default."
  }

  # Glue's shared groups have no retention and keep every run forever.
  assert {
    condition     = aws_cloudwatch_log_group.this[0].retention_in_days == 7
    error_message = "The job's log group must have a retention."
  }
}

run "the_role_reads_its_script_and_nothing_else_in_that_bucket" {
  command = plan

  assert {
    condition     = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "ReadScript"]).Resource == ["arn:aws:s3:::acme-prod-glue-scripts/scripts/reconcile_etl_job.py"]
    error_message = "The script statement must name the one object, not the bucket."
  }

  assert {
    condition     = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "UseTempDir"]).Resource == ["arn:aws:s3:::acme-prod-glue-temp/acme-prod-reconcile/*"]
    error_message = "The temp dir statement must be scoped to the job's prefix."
  }

  assert {
    condition     = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "ListTempDir"]).Condition.StringLike["s3:prefix"] == ["acme-prod-reconcile/*"]
    error_message = "Listing the temp bucket must be limited to the job's prefix."
  }

  # The grants still come through modules/grants, next to the statements the module adds.
  assert {
    condition     = contains([for s in jsondecode(output.policy_json).Statement : s.Sid], "SecretDatabaseSelf")
    error_message = "The declared grants must reach the role."
  }
}

run "a_cmk_on_the_script_bucket_adds_decrypt" {
  command = plan

  variables {
    resources = {
      buckets = {
        glue-scripts = {
          arn         = "arn:aws:s3:::acme-prod-glue-scripts"
          name        = "acme-prod-glue-scripts"
          kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/abcd-1234"
        }
        glue-temp = { arn = "arn:aws:s3:::acme-prod-glue-temp", name = "acme-prod-glue-temp" }
        documents = { arn = "arn:aws:s3:::acme-prod-documents", name = "acme-prod-documents" }
      }
      tables = {
        attributes = { arn = "arn:aws:dynamodb:eu-west-1:111122223333:table/acme-prod-attributes", name = "acme-prod-attributes" }
      }
      secrets = {
        database = { arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:acme-prod-database-AbCdEf", name = "acme-prod-database" }
      }
    }
  }

  assert {
    condition     = one([for s in jsondecode(output.policy_json).Statement : s if s.Sid == "DecryptScript"]).Resource == ["arn:aws:kms:eu-west-1:111122223333:key/abcd-1234"]
    error_message = "An encrypted script bucket must come with kms:Decrypt on its key."
  }
}

run "no_network_no_connection" {
  command = plan

  assert {
    condition     = length(aws_glue_connection.this) == 0 && output.security_group_id == null
    error_message = "Without `network` the module must create neither a connection nor a security group."
  }

  assert {
    condition     = length(aws_glue_job.this.connections) == 0
    error_message = "Without `network` the job must have no connections."
  }
}

run "jdbc_connection_inside_the_vpc" {
  command = plan

  variables {
    network = {
      subnet_id = "subnet-0123456789abcdef0"
      jdbc      = { url = "jdbc:postgresql://db.internal:5432/app", secret = "database" }
    }
  }

  assert {
    condition     = aws_glue_connection.this[0].connection_type == "JDBC"
    error_message = "With `jdbc` the connection must be of type JDBC."
  }

  # The credentials stay in Secrets Manager: the connection holds the secret's name only.
  assert {
    condition     = aws_glue_connection.this[0].connection_properties["SECRET_ID"] == "acme-prod-database"
    error_message = "The connection must reference the secret by name."
  }

  assert {
    condition     = !contains(keys(aws_glue_connection.this[0].connection_properties), "PASSWORD")
    error_message = "No password must ever reach the connection, and with it the state."
  }

  assert {
    condition     = aws_glue_connection.this[0].physical_connection_requirements[0].availability_zone == "eu-west-1a"
    error_message = "The availability zone must be read from the subnet."
  }

  assert {
    condition     = aws_glue_job.this.connections == tolist(["acme-prod-reconcile"])
    error_message = "The job must use the connection the module created."
  }
}

run "network_connection_without_jdbc" {
  command = plan

  variables {
    network     = { subnet_id = "subnet-0123456789abcdef0", security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"] }
    connections = ["shared-postgres"]
  }

  assert {
    condition     = aws_glue_connection.this[0].connection_type == "NETWORK"
    error_message = "Without `jdbc` the connection must be of type NETWORK."
  }

  assert {
    condition     = length(aws_glue_connection.this[0].connection_properties) == 0
    error_message = "A NETWORK connection carries no properties."
  }

  # The existing connections are attached after the module's own.
  assert {
    condition     = aws_glue_job.this.connections == tolist(["acme-prod-reconcile", "shared-postgres"])
    error_message = "Existing connections must be attached next to the module's."
  }
}

run "failure_notification" {
  command = plan

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.failed[0].event_pattern) == {
      source        = ["aws.glue"]
      "detail-type" = ["Glue Job State Change"]
      detail        = { jobName = ["acme-prod-reconcile"], state = ["FAILED", "TIMEOUT", "ERROR"] }
    }
    error_message = "The rule must match this job's runs ending in failure, timeout or error — and not the ones somebody stopped."
  }

  assert {
    condition     = aws_cloudwatch_event_target.failed[0].arn == "arn:aws:sns:eu-west-1:111122223333:acme-prod-alarms"
    error_message = "The rule must notify the declared actions."
  }
}

run "observability_can_be_turned_off" {
  command = plan

  variables {
    observability = {
      continuous_logging = false
      metrics            = false
      job_insights       = false
      alarms             = { enabled = false }
    }
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.this) == 0 && length(aws_cloudwatch_event_rule.failed) == 0
    error_message = "With observability off the module must create neither the log group nor the rule."
  }

  assert {
    condition     = keys(output.default_arguments) == ["--DYNAMO_TABLE", "--ENV", "--SECRET_NAME", "--TempDir", "--job-bookmark-option", "--job-language", "--target_bucket"]
    error_message = "With observability off no observability argument must reach the job."
  }
}

run "python_shell" {
  command = plan

  variables {
    command      = "pythonshell"
    glue_version = null
  }

  assert {
    condition     = aws_glue_job.this.max_capacity == 0.0625
    error_message = "A Python shell job must be sized in DPUs."
  }

  assert {
    condition     = aws_glue_job.this.glue_version == "3.0"
    error_message = "A Python shell job must default to Glue 3.0, the version that runs Python 3.9."
  }

  assert {
    condition     = aws_glue_job.this.command[0].python_version == "3.9"
    error_message = "A Python shell job must default to Python 3.9."
  }

  # Continuous logging, metrics and insights are Spark features.
  assert {
    condition     = length(aws_cloudwatch_log_group.this) == 0 && !contains(keys(output.default_arguments), "--enable-metrics")
    error_message = "A Python shell job must get neither the log group nor the Spark flags."
  }
}

run "long_names_fit_iam_and_eventbridge" {
  command = plan

  variables {
    name = "reconcile-the-supplier-catalogue-with-the-warehouse-stock"
  }

  assert {
    condition     = length(aws_iam_role.this.name) <= 64 && length(aws_cloudwatch_event_rule.failed[0].name) <= 64
    error_message = "The role's and the rule's names must stay within 64 characters."
  }
}
