# examples/function

À-la-carte use of [`modules/function`](../../modules/function): three functions with different
dependencies, on top of supporting resources written natively.

The supporting resources (bucket, table, topic, queue with a DLQ, secret) are native **on purpose**: a
real project would use `modules/bucket`, `modules/table`, `modules/topic`, `modules/queue` and
`modules/secret` and pass their outputs into the same registry. Keeping them native here shows that the
module does not require the rest of the library to be useful.

| Function | What it demonstrates |
|---|---|
| `api` | references to all five resource types, read/write grants, alarms with a destination |
| `worker` | event source mapping from a queue, `consume`, on-failure destination towards the DLQ |
| `minimal` | the module's defaults, and the absence of network permissions outside a VPC |

## Running it

```bash
terraform init
terraform plan
```

The `plan` requires AWS credentials. To check the wiring **without** credentials:

```bash
terraform test
```

The tests use a mocked provider and run the whole plan. They are not decorative: they found two real
defects while this example was being written — a registry not passed to a module, and a `count` in the
upstream module that depended on an ARN not yet known at plan time. `terraform validate` sees neither,
because it evaluates neither variable validations nor preconditions.

## Things to look at in the output

```bash
terraform output iam_decisions
```

`network` must be `false` on all three functions: none of them is in a VPC, so none of them must have the
ENI permissions.

```bash
terraform output api_policy | jq .
```

The policy generated from the grants. Note that `ListBucket` is on the bucket's ARN and `GetObject` on
`arn/*`: they are different resources, and granting them on the same ARN would produce an ineffective
policy with no syntax error at all.

## Cleaning up

```bash
terraform destroy
```

The bucket must be emptied before the destroy if it contains objects.
