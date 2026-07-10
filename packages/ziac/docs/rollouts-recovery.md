# Regional Rollouts And Recovery

Ziac's built-in `global-container` stack updates its primary Cloud Run region
first. Every other regional service depends on that canary service, so the
executor cannot start the fleet until Google reports the canary revision ready.

Library users opt in explicitly:

```zig
.rollout = .{
    .strategy = .canary_then_fleet,
    .canary_region = "europe-west1",
},
```

The alternative `.parallel` strategy preserves independent regional updates.
The canary region must occur in the component's unique region list. The rollout
edge is part of the desired graph digest and every saved plan.

## What The Gate Proves

A Cloud Run create or update remains pending while its Google long-running
operation is active. Ziac accepts the returned service only when:

- `reconciling` is false;
- `terminalCondition.state` is `CONDITION_SUCCEEDED`;
- `latestCreatedRevision` equals `latestReadyRevision`.

Reconciliation in progress is retryable within the resource deadline. A failed
terminal condition is `RemoteOperationFailed`. Startup, liveness, and readiness
probes remain part of the revision template; production mode requires warm
instances plus startup and liveness probes.

This is a regional canary, not a percentage traffic split. A global external
Application Load Balancer continues routing users to the nearest healthy
regional serverless NEG. Google does not support balancing mode, target
capacity, or capacity scalers for serverless NEGs, so Ziac does not invent a
drain or weighting control at that layer. See Google's
[serverless NEG limitations](https://docs.cloud.google.com/load-balancing/docs/negs/serverless-neg-concepts)
and [Cloud Run rollout documentation](https://docs.cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration).

## Image Recovery State

Cloud Run service state exposes:

- `image_ref`: the observed current image;
- `previous_image_ref`: the immediately previous image when available;
- `latest_revision` and `latest_created_revision`;
- `ready`.

The pending update checkpoint retains the old image before polling Google. The
final result preserves it as `previous_image_ref`. Source-built typed image
outputs resolve through state, so config-only updates retain the same recovery
history as literal digest deployments.

Rollback accepts only OCI image references with a 64-character SHA-256 digest.
Tags such as `latest` are deliberately ineligible.

## Roll Back

```sh
ziac rollback \
  --stack global-container \
  --stage prod \
  --provider gcp \
  --allow-live \
  --confirm
```

Confirmation is checked before provider selection or lock acquisition. The
command then:

1. acquires the normal stack/stage writer lock;
2. compiles and clones the complete desired graph;
3. replaces only eligible Cloud Run image inputs with prior digests;
4. rejects create, replace, delete, or non-Cloud-Run update operations;
5. executes through normal provider retries and per-mutation checkpoints;
6. persists resources and resolved outputs through the selected state backend.

The complete graph clone prevents unrelated resources from appearing removed.
During a partial rollout, regions still on the old image remain on that image;
their reconstructed input hash must match desired or observed state. Any other
configuration divergence fails closed.

After a successful rollback, change the configured desired image to the restored
digest before the next normal deploy. Otherwise a normal plan correctly proposes
the newer configured image again. Repeating rollback without that desired-state
change returns `RollbackUnavailable`; it never toggles forward.

If the process exits after a provider mutation, rerun the same `rollback`
command. The checkpointed physical ID and operation handle resume the original
Google operation. Do not use a normal deploy with the unreverted image while a
rollback is incomplete.

## Provider Diagnostics

Deploy and rollback attach a bounded diagnostic recorder to every executor
operation. GCP failures can report:

```text
provider: QuotaExceeded
provider diagnostic: category=quota service=compute.googleapis.com status=429 google_status=RESOURCE_EXHAUSTED request_id=... quota_metric=... quota_limit=...
```

`google.rpc.QuotaInfo`, the first `google.rpc.QuotaFailure` subject,
`Retry-After`, and request IDs are retained in process-local diagnostics.
Messages are redacted and every text field is bounded to 512 bytes. Diagnostics
are never written to state, plans, source archives, or command receipts.

`RateLimited` remains retryable under the resource deadline and configured
zigeffect schedule. `QuotaExceeded` is terminal so operators can request or free
the named quota instead of waiting through blind retries.

## Incident Runbook

1. Stop additional deploy jobs and retain the failed command output.
2. Inspect the stack lock and state serial; do not force-unlock an active owner.
3. Rerun the same deploy if the failure was interruption or retryable rate
   limiting.
4. Run guarded rollback when a ready regional revision must be reverted.
5. Update the configured immutable image to the restored digest.
6. Run a live plan, review the region dependency order, and deploy.
7. Verify HTTPS, database TLS, and regional failover before closing the incident.

The clean-checkout and authenticated release runbooks are in `release.md`.
Rollout evidence may include image digests, revision names, region order,
readiness outcomes, and request IDs; it must not include environment values,
tokens, database URLs, or Secret Manager payloads.
