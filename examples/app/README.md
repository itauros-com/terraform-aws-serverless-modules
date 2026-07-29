# examples/app

A complete serverless application described with [`modules/app`](../../modules/app): four functions, an API
with an authorizer, two topics fanning in onto one queue, a bucket with notifications, a table with a GSI
and TTL, a static site, an ECR repository, a schedule and observability.

The root config is **one call**. All the rest of the file is the description of the application: it is the
shape the project repos will have.

## Running it

```bash
terraform init
terraform test    # checks the wiring without AWS credentials
terraform plan    # requires credentials
```

## What to look at

```bash
terraform output -json wiring | jq
```

**Which routes are public.** `api_route_authorization` gives the effective authorization type per route,
derived from the authorizer. Here only `GET /health` is `NONE`.

**Which topics every queue receives from.** `queue_subscriptions` shows `["audit", "operations"]` on
`events`: the two subscriptions declared on the topic side converged into a single policy document on the
queue, which is the only correct way because SQS allows one per queue.

**That the cycle is broken.** The `documents` bucket notifies the `indexer` function, and `indexer` reads
from the bucket. `queue_bucket_sources` shows the ARN computed from the name: that is what lets the bucket
depend on the queue and the function not depend on the bucket.

**What every role received.** `function_iam` says, for each function, whether it has the network
permissions, tracing, the asynchronous destination and an application policy. Here `network` is `false` on
all four: none of them is in a VPC.

## Trying a wiring error

Change `target_function = "worker"` to `"workr"` in the schedule and run `terraform plan`. The module
reports **all** the wrong references at once, each with the path of the declaration:

```
Unresolved cross-references:
  - schedules['cleanup'].target_function references the function 'workr', which is not in `functions`
```

In the previous wiring the same mistake on a reference in `environment_variables` did not stop the plan: the
string `workr` reached the Lambda and the problem was discovered at runtime.

## Deploying the code

The example uses a placeholder zip. In a real project CI builds the images and writes the tag:

```hcl
functions = {
  files = {
    image = "${module.app.registries["files"].url}:v1.2.3"
  }
}
```

With `ignore_code_changes = false` Terraform goes back to being the truth about which code is deployed, a
rollback becomes a `git revert` and promotion between environments a tag change in a PR.

## Cleaning up

```bash
terraform destroy
```

The example sets `deletion_protection = false` on the table and `force_destroy = true` on the buckets. Those
are the opposite of the modules' defaults, precisely because the modules' defaults protect the data.
