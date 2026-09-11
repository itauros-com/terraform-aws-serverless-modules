# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

A **breaking change** in this repo is any change to the variable contract or to the state addresses the
modules generate. The two must be noted separately: the first breaks callers' `plan`, the second
requires `moved` blocks on their side.

## [Unreleased]

### Fixed

- `modules/schedule` — the role's name no longer runs past the 64 characters IAM allows. A schedule is
  the resource most likely to overflow: `<project>-<environment>-<what it does>` plus the `-scheduler`
  suffix reaches 66 on a name as ordinary as `accessi-process-expirations-daily`, and the provider
  rejected it at **apply**, after the plan had been reviewed and approved.

  The name is now shortened deterministically — 55 characters, then 8 hex of the full name's hash.
  Plain truncation would collide between two schedules sharing a long prefix, which is exactly what a
  `<project>-<environment>-` convention produces, and the collision would surface as an
  `EntityAlreadyExists` on whichever applied second. `role_name` is there to choose the short name
  yourself.

  Found while planning a real configuration onto the library: the schedules were the one thing that
  stopped the plan outright.

## [0.1.2] — 2026-09-11

### Added

- **`modules/cdn`** — a CloudFront distribution in front of origins it does **not** create, routed by
  path. It is the case `modules/site` cannot express: `site` owns its bucket and serves it whole, so
  one distribution means one bucket and one behavior.

  Origins are S3 buckets reached through an Origin Access Control — one per origin, with the read
  statement returned for the bucket's single policy — or custom HTTPS origins, an API Gateway among
  them. Behaviors are a **list** and not a map: CloudFront stops at the first `path_pattern` that
  matches, and a map would be ordered by key, turning a semantic order into an alphabetical accident.

  `preset` resolves the cache policy, the origin request policy, the allowed methods and compression
  together, because they only make sense together. `api` is there for one failure in particular: an
  API served with the static cache policy never receives the `Authorization` header and answers 401
  on everything, with nothing anywhere saying why. The managed policies are resolved by **name**, so
  that a wrong one fails at plan instead of producing a distribution that misbehaves in silence.

  Signed URLs through `key_groups`, which take public keys only — the private one belongs to whoever
  signs. The guardrail that justifies the module: an origin declared `require_signed_urls` and served
  by a behavior with no `trusted_key_groups` **stops the plan**. That mistake is invisible otherwise,
  because `trusted_key_groups` belongs to the behavior and not to the distribution: a key group on the
  default behavior protects nothing on a path that has a behavior of its own, the bucket stays private
  the whole time, and the objects are served to anyone who knows a key.

  Six more preconditions cover an unknown origin or key group, two behaviors sharing a `path_pattern`,
  an origin no behavior serves, aliases with no certificate, a certificate outside us-east-1 and a
  zone with no aliases.

- `modules/app` — `cdns`, the composition of the above. Origins are declared by key: `bucket` resolves
  to the name computed from the prefix, `http_api` to the host of the API's endpoint. The statements of
  every distribution fronting the same bucket are **merged here** into the one policy S3 allows it —
  the composition is the only place that sees every contributor, and they are merged as objects and
  encoded once, because an encoded document embeds an ARN that is unknown at plan.


- `modules/security-group` — `egress_prefix_list_rules` and `ingress_prefix_list_rules`, rules whose
  destination is an AWS **managed prefix list**. It is what reaches S3 or DynamoDB through a gateway
  endpoint, where the destination is not a CIDR anyone can write down. Without them the only way out of a
  closed security group towards S3 is `0.0.0.0/0`, which opens the whole internet in order to reach one
  service — and the symptom of the missing rule is not a denied permission but an `i/o timeout`, because
  the packet leaves and nobody answers.

  The contract takes a **list** of IDs where upstream wants a comma-separated string: a typo inside a
  string reaches AWS as a prefix list that does not exist. Two validations reject an empty list and an ID
  that is not a `pl-`, the mistake to expect being a security group ID. A prefix list rule counts as an
  egress rule for the "no egress at all" precondition.

- `modules/app` — `alarms` on `queues`, `topics` and `tables`, with `enabled` and the thresholds.

  The composition used to pass those primitives only `alarms.actions`, so their alarms were on and there
  was no way to turn them off from the caller. That contradicted what the library already promised
  elsewhere: a migration of an existing configuration is supposed to be able to produce a plan with no
  changes, and prove the translation faithful before anything new is switched on. It could be done for
  functions and for the dashboard, but not for a queue, a topic or a table — and eleven alarms nobody
  asked for yet are enough to hide the one diff that matters.

  `actions` stays out of the caller's reach on purpose: the alarm topic's ARN is injected by the
  composition, so an alarm that notifies nobody remains inexpressible.

- `modules/app` — `egress_prefix_list_rules` and `ingress_prefix_list_rules` passed through to
  `security_groups`.

### Notes

Additive to the variable contract: every new field has a default reproducing the previous behaviour, and
no state address changes. Existing callers see no diff.

A PATCH and not a MINOR despite a whole new module, for the same reason as 0.1.1: nothing existing
changes shape. `modules/cdn` is new surface nobody is calling yet, the new fields on `modules/app` and
`modules/security-group` all default to the previous behaviour, and no state address moves. Upgrading
from 0.1.1 produces no diff until a caller writes something that uses the additions.

## [0.1.1] — 2026-08-19

### Fixed

- `modules/site` no longer declares an `aws_s3_bucket_policy` of its own. S3 stores **a single policy
  document per bucket** and every `PutBucketPolicy` replaces it whole, while `modules/bucket` always
  creates a policy — its two TLS statements are unconditional. The two resources replaced each other in a
  non-deterministic order, with neither Terraform nor AWS reporting the conflict: what stayed on the bucket
  was the document of whichever applied last, so **either** CloudFront's read access through the OAC — and
  the distribution answers 403 on everything — **or** the TLS enforcement. The OAC statement now goes in
  through `policy_json`, and the upstream module merges it with its own into one document.

  Expect **one update to the bucket's policy** on the first apply, adding back whichever statements the
  duplicate had been overwriting. It is worth checking which ones those were: if the OAC statement was the
  one winning in production, the bucket has been running without the deny on non-TLS traffic.

  The statement's bucket ARN is computed from the name rather than read back from `module.bucket`, the same
  way `modules/app` does it, so the module's input never depends on its own output.

### Added

- `modules/bucket` — `attach_policy`, to declare that `policy_json` takes part in the bucket's policy when
  the document is not known at plan time because it references the ARN of a resource that does not exist
  yet: an unknown value compared with `null` is unknown too. Null by default, i.e. derived from
  `policy_json` as before. New `policy_json_attached` output.
- `modules/site` — `bucket_policy_json` output, the document this module contributes to the bucket's
  policy. The bucket's effective policy is no longer that document alone, and the output makes the
  difference inspectable.

### State addresses

`module.<site>.aws_s3_bucket_policy.this` is gone. **Callers need no `moved` block**: `modules/site` ships
a `removed` block with `lifecycle { destroy = false }`, so the resource is forgotten rather than destroyed.

`destroy = false` is not caution. Destroying it would call `DeleteBucketPolicy`, which removes the entire
document — including the statements the surviving resource manages — and Terraform does not order a destroy
against an update of another resource on the same API object. The site could be left with no policy at all,
answering 403 on everything, until the next apply.

The `removed` block stays until the next MAJOR; for anyone starting from this version it is a no-op.

### Notes

The variable contract does not change incompatibly — `attach_policy` is additive and its default reproduces
the previous behaviour — and the state migration is automatic. Hence a PATCH and not a MINOR, despite a
state address disappearing.

## [0.1.0] — 2026-07-29

First release. The variable contract should be considered stable but not yet proven in production:
until 1.0.0 a MINOR may contain breaking changes, noted here as such.

### Added

- Repo scaffold: conventions, `Makefile`, CI (fmt, validate, test, tflint, trivy, terraform-docs, and
  `plan` over the examples behind an optional test account).
- `modules/grants` — capability → IAM action table. A pure module: no provider, no resources, no data
  sources. The table is exposed as an output, so that anyone who needs to read it or invert it from the
  outside does not duplicate it and watch it drift.
- `modules/function` — a Lambda wrapping `terraform-aws-modules/lambda/aws ~> 8.0`, with:
  - typed references (`env_from`) instead of inference from the environment variable's name;
  - capability-derived IAM (`grants`), with the cross-cutting permissions attached according to the
    function's actual configuration;
  - network permissions **conditional** on the presence of `vpc`;
  - an `on_failure` destination for asynchronous invocations, enabled by default;
  - X-Ray tracing and three alarms (errors, throttles, p99 duration against the timeout);
  - a coherence check between an event source mapping on a queue and the `consume` capability.
- `modules/queue` — SQS with a DLQ and `maxReceiveCount` on the redrive, long polling, encryption, SNS
  subscriptions declared queue-side and a single policy with one statement per source, alarms on message
  age and on a non-empty DLQ.
- `modules/topic` — SNS with non-SQS subscriptions, a policy for service publishers, an alarm on failed
  deliveries. Rejects `sqs` subscriptions pointing to `modules/queue`, and stops the plan if a service
  publisher is declared on a topic encrypted with the AWS-managed key.
- `modules/table` — DynamoDB with `range_key`, GSI/LSI, TTL, streams, PITR and deletion protection
  enabled by default; checks that key attributes are declared and that none are declared but unused.
- `modules/bucket` — S3 always private, versioning and encryption enabled, notifications towards
  queues, topics and functions in a single configuration, with the invocation permission created
  alongside the notification.
- `modules/secret` — create-only Secrets Manager: no value in state, changes to the value ignored, and
  an output telling whether the value was ever managed by Terraform. With no `initial_value` no secret
  version is created at all: the secret exists and is empty, and `GetSecretValue` returns
  `ResourceNotFoundException` until somebody populates it. That is the intended failure — it names the
  problem, where a placeholder value would be handed to the application and fail further downstream.
- `modules/security-group` — a VPC identifiable by its `Name` tag, `cidr_blocks = "vpc"` resolved to the
  VPC's CIDR, and the plan stopped on a group with no egress rule at all.
- `modules/http-api` — HTTP API Gateway with `authorization_type` **derived** from the authorizer's type
  instead of declared by hand, one invocation permission per function created by the API itself, JSON
  access logs that include the integration and authorizer error, stage throttling.
- `modules/site` — a private bucket with CloudFront and an Origin Access Control linked by direct
  reference, an optional SPA preset, managed security headers, guardrails on the certificate's region
  and on the WebACL's scope. The distribution is written natively.
- `modules/registry` — ECR with immutable tags and exceptions, and two distinct lifecycle rules for
  untagged and tagged images.
- `modules/schedule` — EventBridge Scheduler with a per-schedule role, a single action per target type,
  and a mandatory DLQ unless explicitly declined.
- `modules/observability` — the alarm topic to pass to the other modules, a dashboard built by resource
  type, log forwarding to an external destination, a composite alarm.
- `modules/app` — the composition. It instantiates the primitives, builds the resource registry,
  resolves every reference by key, inverts subscriptions from the topic side to the queue side, derives
  route authorization, creates the alarm topic before everything else and wires it into every primitive.
  It checks cross-references **all at once**, reporting them with the path of the declaration instead of
  one per plan cycle.
- `examples/app` — a complete application in a root config with a single call: four functions, an API
  with an authorizer, fan-in from two topics, a bucket with notifications, a static site, ECR, a
  schedule and observability.
- `examples/function` — à-la-carte usage with three functions, a queue with a DLQ and alarms.
- `examples/complete` — every primitive wired together: it exercises fan-in from two topics onto one
  queue, the breaking of the bucket ↔ queue cycle, and the functions' effective permissions.
- 247 tests using `mock_provider`, runnable without AWS credentials.

### Implementation notes

- **Why wrap instead of rewrite.** Keeping `terraform-aws-modules/lambda/aws` inside `modules/function`
  keeps the state addresses a prefix change apart
  (`module.functions["x"].aws_lambda_function.this[0]` →
  `module.function["x"].module.lambda.aws_lambda_function.this[0]`). Anyone reorganizing their
  configuration gets away with `moved` blocks that can be generated mechanically, instead of remapping
  dozens of them by hand.
- **`count` and unknown values.** The flags feeding a `count` in the upstream module
  (`attach_policy_json`, `attach_async_event_policy`) derive from the *shape* of the inputs and not from
  the ARNs: the ARNs come from resources not yet created and are unknown at plan time. This was a bug
  found by the example's tests, invisible in the unit tests where the ARNs are literals.
- **The examples are part of the test suite.** `terraform validate` evaluates neither variable
  validations nor preconditions, so it does not see the examples' wiring errors.
- **Stable output types.** An output that changes type depending on the configuration (`{}` versus an
  object, tuple versus list) breaks callers iterating over it with `for_each`, and in tests produces a
  comparison that is always false even with identical values. Outputs of variable shape go through
  `tomap` or `tolist`.
- **Assertions on values known at plan time.** ARNs and IDs assigned by AWS are unknown at plan: where
  the link itself needs verifying — `site`'s OAC — the test uses `mock_resource` and `command = apply`,
  which with a mocked provider never touches AWS.
- **Three deviations from the rule of wrapping.** The fan-in queue policy, the CloudFront distribution
  and `modules/secret` are written natively. In the first case upstream does not cover the
  one-policy-per-queue constraint; in the second the OAC's indirection by key is the very cause of the
  defect the module corrects; in the third `terraform-aws-modules/secrets-manager` always creates exactly
  one secret version — its two counts are complementary and there is no way to get zero — and a version
  with no value is rejected by AWS, which makes an empty secret inexpressible through it.
