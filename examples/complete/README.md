# examples/complete

Every primitive wired together: a table, a bucket, a secret, two topics, two queues and three functions.

It exists to verify the **cross-wiring**, which is where the real problems come from and where the
individual modules' tests do not reach.

## What it demonstrates

**The registry is composed once.** Every primitive exposes `registry_entry` already in the expected shape,
CMK included. The resulting `locals.resources` is passed identically to every function, and from there
`env_from` and `grants` resolve by key.

**SNS→SQS fan-in.** Two topics, `operations` and `audit`, publish onto the same `events` queue. SQS allows a
single `Policy` attribute per queue: the two authorizations must converge into a single document with two
statements, and the only place that can be guaranteed from is the queue. The test checks it on the Sids.

**How a cycle is broken.** The `documents` bucket notifies the `ingest` queue, so it needs its ARN. The queue
must authorize `s3.amazonaws.com`, so it needs the bucket's ARN. Referring to both modules would be a cycle:
the bucket's ARN is passed as a string, computed from the name.

**Functions outside the VPC do not receive the ENI permissions.** `vpc_name` is null by default and the test
verifies that `iam.network` is `false` on all three functions. Setting `vpc_name` and `private_subnet_ids`
puts the functions in a VPC and the permissions appear.

**The secret's value does not go through Terraform.** `secret_value_in_state` must be `false`.

## Running it

```bash
terraform init
terraform test    # checks the wiring without AWS credentials
terraform plan    # requires credentials
terraform apply
```

With a VPC:

```bash
terraform apply -var 'vpc_name=acme-dev-vpc' -var 'private_subnet_ids=["subnet-aaa","subnet-bbb"]'
```

## Things to look at

```bash
terraform output queue_policies
# events → ["SnsFromAudit", "SnsFromOperations"]   ← two statements, one document
# ingest → ["S3From0"]

terraform output iam_decisions
terraform output api_policy | jq '.Statement[] | {Sid, Action, Resource}'
```

In the `api` function's policy, `ListBucket` is on the bucket's ARN and `GetObject`/`PutObject` on `arn/*`:
different resources, just like DynamoDB's `Query` which covers `arn/index/*` too.

## Cleaning up

```bash
terraform destroy
```

The example deliberately sets `deletion_protection = false` on the table, `force_destroy = true` on the
bucket and `recovery_window_in_days = 0` on the secret. All of those are the opposite of the modules'
defaults, precisely because the modules' defaults protect the data and here there is none.
