# Immutable Saved Plans

Ziac can persist a reviewed plan and later execute those exact operations
without replanning:

```sh
zig-out/bin/ziac plan \
  --stack hello-global \
  --stage prod \
  --out artifacts/hello-global-prod.plan.json

zig-out/bin/ziac deploy \
  --stack hello-global \
  --stage prod \
  --plan artifacts/hello-global-prod.plan.json
```

Plan creation is exclusive. Ziac returns `PlanAlreadyExists` instead of
overwriting an existing artifact. Use a new path for every newly reviewed plan.

## What A Plan Binds

Saved plan format v1 records:

- stack and stage;
- creation time and content digest;
- state lineage and serial;
- the current compiled desired-graph digest;
- full create, update, replacement, delete, read, and noop operations;
- canonical desired inputs, lifecycle settings, dependencies, and reasons;
- an operation-integrity digest and derived approval requirement.

At apply time Ziac still compiles the selected stack. This reruns comptime Env,
binding, provider-set, and output-wiring validation and hashes the current graph.
It does not invoke either planner. Provider mutations come from the loaded plan
only.

The apply fails before provider access when the target, state lineage, state
serial, current graph, operation integrity, or plan digest differs. Create a new
plan against the current code and state instead of modifying a stale artifact.

## Destructive Approval

Every delete or replacement requires explicit confirmation in the executor.
For a saved plan, approval is tied to its exact lowercase digest:

```sh
zig-out/bin/ziac deploy \
  --stack hello-global \
  --stage prod \
  --plan artifacts/hello-global-prod.plan.json \
  --approve 9f0c...exact-64-character-plan-digest
```

`plan` prints `Approval required: yes` and the digest when its operation set is
destructive. JSON receipts expose the same values as `plan_digest`, `plan_path`,
and `approval_required` under schema `ziac.command.v2`.

Direct deploys with a delete or replacement require `--confirm`. Full destroy
also requires `--confirm`:

```sh
zig-out/bin/ziac destroy \
  --stack hello-global \
  --stage prod \
  --confirm
```

Lifecycle `protect` is stronger than either confirmation mechanism. A protected
delete or replacement cannot be planned. First change the declaration to
unprotected and deploy that non-destructive lifecycle update, then create and
approve a new destructive plan. This is the required workflow for protected
CockroachDB clusters and databases.

## Secret Boundary

Plan inputs use the canonical Ziac value algebra. Secrets persist only as typed
provider references such as Secret Manager resource/version coordinates.
Secret payloads are not accepted by the plan serializer, and CLI receipts do
not print resource inputs. Output references and unknown values remain typed.

The loader verifies each desired input hash and then recomputes operation and
top-level plan digests. Files larger than 64 MiB, malformed JSON, future format
versions, invalid hashes, unknown providers or operation kinds, and invalid
targets fail closed.

## CI Review Flow

Use two jobs with an immutable artifact boundary:

1. The plan job authenticates with Workload Identity Federation, runs
   `ziac plan --out`, publishes the plan file, and exposes its digest.
2. A protected environment reviews the plan summary and digest.
3. The deploy job downloads that exact artifact and runs `ziac deploy --plan`.
4. When `approval_required` is true, the reviewed digest is passed through
   `--approve`.

Remote state generation checks and writer leases remain active during apply.
Approval never disables state CAS, stale-plan rejection, or lifecycle
protection.

