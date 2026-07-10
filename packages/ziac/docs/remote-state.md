# GCS Remote State

Ziac uses local state by default. Set `ZIAC_STATE_BUCKET` to move resources,
outputs, checkpoints, and writer locks to Google Cloud Storage:

```sh
export ZIAC_STATE_BUCKET=my-ziac-state
export ZIAC_STATE_PREFIX=ziac/state # optional; this is the default
zig-out/bin/ziac plan --stack api --stage prod
```

Remote state uses the existing native ADC implementation. Authorized-user,
service-account, metadata, and Workload Identity Federation credentials work;
`gcloud` and downloaded service-account key JSON are not required.

## Bootstrap

Create the state bucket outside the stack whose state it stores. Enable uniform
bucket-level access, public access prevention, and object versioning. Grant the
deployment identity the smallest bucket-scoped role that includes
`storage.objects.get`, `storage.objects.create`, and `storage.objects.delete`.
Object replacement needs both create and delete permissions.

Google documents the JSON API upload precondition on
[Objects: insert](https://docs.cloud.google.com/storage/docs/json_api/v1/objects/insert),
generation-pinned downloads on
[Objects: get](https://docs.cloud.google.com/storage/docs/json_api/v1/objects/get),
and the race guarantees in
[Request preconditions](https://docs.cloud.google.com/storage/docs/request-preconditions).

## Object Layout

The default object keys are:

```text
ziac/state/<stack>/<stage>/resources.json
ziac/state/<stack>/<stage>/outputs.json
ziac/state/<stack>/<stage>/lock.json
```

Stack, stage, and prefix segments are validated before HTTP. Resource state
uses the same versioned deterministic JSON as local state. Output values remain
redacted and secret resource outputs remain typed references. Downloads and
uploads are bounded to 64 MiB by default so corrupt or unexpected objects cannot
cause unbounded allocation.

## Concurrency

Every resource or output write is conditional:

- a missing object is created with `ifGenerationMatch=0`;
- generation N is replaced only with `ifGenerationMatch=N`;
- deletes name the exact generation being removed.

A read fetches metadata first, then requests bytes pinned to that generation.
If another writer changes state, GCS returns a failed precondition and Ziac
reports `StateConflict`. Ziac never retries that conflict as an unconditional
write. Re-run `plan` against the new state before applying again.

Writer locks are conditional objects carrying lineage, owner, command,
acquisition time, and expiry. The default lease is one hour and renews before
each provider checkpoint. An active second writer receives `LockConflict`. An
expired lock is replaced atomically with `ifGenerationMatch` against its
inspected generation, so there is no unlocked interval and a newer writer
cannot be overwritten accidentally.

## Migration

Keep the local state files in place and select the GCS backend, then run:

```sh
export ZIAC_STATE_BUCKET=my-ziac-state
zig-out/bin/ziac state-migrate --stack api --stage prod
```

Migration requires an absent remote resource and output object. It copies the
released local format, preserves lineage and serial, migrates only redacted
outputs, reloads the remote object, and verifies metadata. It does not delete
the local files. A second migration fails with `TargetStateExists`.

## Recovery

Inspect state normally:

```sh
zig-out/bin/ziac state --stack api --stage prod
zig-out/bin/ziac outputs --stack api --stage prod
```

After verifying that no writer is running, remove a stranded lock with its
lineage:

```sh
zig-out/bin/ziac unlock \
  --stack api \
  --stage prod \
  --lineage api/prod
```

`--force` bypasses only the lineage check. Remote deletion still targets the
exact lock generation. If state is corrupted, restore a prior object generation
through GCS administration, then run `plan` or `refresh`; do not hand-edit live
state while a writer lease exists.

## Failure Policy

- Missing or invalid ADC fails remote-state selection; Ziac never silently
  falls back to local files.
- Invalid JSON, future state versions, or lineage mismatch fail before provider
  access.
- Authentication, authorization, quota, timeout, cancellation, and generation
  conflicts remain distinct errors.
- Diagnostics never include object bytes, authorization headers, token values,
  or secret plaintext.
