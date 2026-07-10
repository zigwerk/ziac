# Ziac Regional Rollout And Recovery Design

## Status

Validated design for M8.4 of the Ziac end-to-end delivery roadmap.

## Goal

Make global Cloud Run image updates fail closed at a regional canary, prove the
new revision reached Cloud Run's serving state before continuing, retain an
immutable previous image for every regional service, and provide a guarded,
checkpointed rollback command with actionable provider diagnostics.

## Constraints

- Ziac manages one Cloud Run service and one serverless NEG per region.
- The global external Application Load Balancer remains the nearest-region
  request router.
- Serverless NEGs do not support balancing mode, target capacity, or capacity
  scalers. Regional rollout must not claim to drain or weight those backends.
- Cloud Run v2 long-running operations and service conditions are the provider
  source of truth for revision readiness.
- Existing state locking, generation CAS, saved-plan integrity, operation
  handles, deadlines, cancellation, and lifecycle protection remain active.
- Rollback images must be immutable Artifact Registry digest references.
- No secret value or unredacted provider payload may enter state, diagnostics,
  receipts, or logs.

Google references:

- [Cloud Run rollouts and rollbacks](https://docs.cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration)
- [Cloud Run v2 Service API](https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.services)
- [Cloud Run health checks](https://docs.cloud.google.com/run/docs/configuring/healthchecks)
- [Serverless NEG limitations](https://docs.cloud.google.com/load-balancing/docs/negs/serverless-neg-concepts)

## Regional Canary Policy

`gcp.global.ContainerService` gains a rollout policy:

```zig
.rollout = .{
    .strategy = .canary_then_fleet,
    .canary_region = "europe-west1",
}
```

Supported strategies are:

- `parallel`: preserve the existing graph and update all independent regional
  services concurrently;
- `canary_then_fleet`: every non-canary Cloud Run service depends on the
  canary Cloud Run service.

The canary region must be non-empty and must occur exactly once in the selected
service regions. A canary dependency is part of the desired graph digest and
therefore part of saved-plan review.

This is a regional canary, not a percentage traffic split. The canary service
receives its normal regional traffic after its revision is ready. If it fails,
the executor cancels the dependent fleet operations. Independent infrastructure
that has already completed remains checkpointed.

The built-in global container stack uses the provider primary region as the
canary by default. Library users can explicitly retain parallel behavior.

## Cloud Run Readiness Contract

Cloud Run service schema version 3 adds these outputs:

- `image_ref`: the currently observed container image;
- `previous_image_ref`: the immediately previous immutable image, or an
  unknown value when no rollback target exists;
- `latest_created_revision`: the newest revision Cloud Run created;
- `ready`: true only when reconciliation is complete, the terminal condition
  succeeded, and latest-created equals latest-ready.

Create and update still return a pending result with the Google operation name.
The executor checkpoints that handle before polling. A completed operation is
accepted only when the returned service satisfies the readiness contract.
Reconciliation in progress is transient; a failed terminal condition is a
remote-operation failure. This means dependent regional updates cannot begin
merely because the PATCH request was accepted.

`previous_image_ref` is derived from the observed service before an update and
is preserved through the pending checkpoint and later refreshes. A successful
rollback stores the formerly current image as the next previous image, while
the rollback command itself refuses to toggle forward when the configured
desired image still differs from the observed rollback image.

## Rollback Graph

`rollout.buildRollbackGraphAlloc` clones the complete current desired graph so
unrelated resources remain present and cannot become accidental deletes. For
each `gcp.run.Service` it resolves:

1. configured desired image;
2. currently observed `image_ref` from state;
3. stored `previous_image_ref` from state.

If current equals desired and the previous image is a distinct immutable
digest, the cloned node's image input is replaced with that previous image. If
current already differs from desired, as after a partial rollout or completed
rollback, the clone keeps the current image. At least one real inverse update
must exist or the command fails with `RollbackUnavailable`.

The cloned graph keeps every dependency and lifecycle setting. The normal plan
builder and executor then provide operation ordering, lineage/serial
preconditions, provider retries, pending-operation handles, per-mutation
checkpoints, and GCS generation CAS.

## CLI Contract

```text
ziac rollback \
  --stack global-container \
  --stage prod \
  --provider gcp \
  --allow-live \
  --confirm
```

The command rejects a missing `--confirm` before provider selection or lock
acquisition. It acquires the normal stack writer lock, loads state, compiles the
normal stack, constructs the rollback graph, creates a reviewed in-memory plan,
and executes it through the normal provider registry and checkpoint.

The command receipt reports update/noop counts and the resulting state serial.
After rollback, operators must change the configured desired image before the
next normal deploy; otherwise a normal plan correctly proposes the newer image
again. An interrupted rollback is resumed by rerunning the same rollback
command, not by running a normal deploy with the unreverted desired image.

## Provider Diagnostics

The generic provider context gains a thread-safe, bounded diagnostic recorder.
GCP HTTP failures publish only structured, redacted fields:

- provider category and API service;
- HTTP and Google status;
- request ID;
- retry delay;
- quota metric, quota limit ID, and bounded quota subject when present;
- redacted message.

The GCP client parses both `google.rpc.QuotaInfo` and the first
`google.rpc.QuotaFailure` violation. The executor attaches the recorder to each
operation context. On failure the CLI prints the stable provider error followed
by one bounded diagnostic line. Diagnostics are process-local and never enter
state or saved plans.

## Failure And Recovery Cases

- Canary revision fails readiness: fleet services do not update; state records
  the canary failure and prior image remains available.
- Process exits after PATCH: the checkpointed Google operation handle is polled
  on rerun without issuing a duplicate mutation.
- Process exits between regional updates: completed regions remain durable and
  dependent regions resume from state.
- Rollback exits after PATCH: rerunning `rollback --confirm` resumes the
  checkpointed operation and continues the inverse graph.
- GCS CAS or lease renewal fails: execution stops without treating provider
  success as durable local success.
- Quota exhaustion: no blind retry; the CLI reports the quota identifiers.
- Rate limiting with `Retry-After`: executor retry policy remains bounded and
  the diagnostic reports the requested delay.

## Acceptance

- Invalid/missing canary regions fail graph construction.
- A canary service is the direct dependency of every fleet service.
- Saved plans contain those dependency edges.
- Cloud Run create/update does not complete until service readiness is proven.
- Failed terminal conditions return `RemoteOperationFailed`.
- State retains current and previous immutable image references without secret
  payloads.
- Rollback graph changes only eligible Cloud Run image inputs and never plans
  unrelated deletes.
- Rollback requires confirmation and uses normal locking/checkpoints.
- Partial rollout and interrupted rollback tests resume deterministically.
- Quota and rate-limit fixtures produce bounded, redacted CLI diagnostics.
- Full Ziac, examples, repository, zigeffect std/Postgres, hygiene, and local
  CockroachDB TLS gates pass.
