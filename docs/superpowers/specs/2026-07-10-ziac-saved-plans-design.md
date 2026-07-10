# Ziac Immutable Saved Plans Design

Date: 2026-07-10

Status: validated for implementation

## Objective

Add a reviewable, content-addressed plan artifact that Ziac can apply without
replanning. A saved plan must bind the reviewed operations to the selected
stack and stage, current state lineage and serial, and the currently compiled
desired graph. It must never contain secret plaintext.

## Existing Foundation

`plan.PlanPreconditions` already records:

- state lineage hash;
- state serial;
- desired graph digest;
- operation digest.

The executor already checks lineage, serial, and operation integrity before
provider access. The saved-plan work persists these contracts, adds stack and
stage identity, validates the current desired graph, and makes destructive
approval specific to one exact plan digest.

## Command Contract

Create a plan:

```sh
ziac plan --stack api --stage prod --out artifacts/api-prod.plan.json
```

Apply the exact reviewed plan:

```sh
ziac deploy \
  --stack api \
  --stage prod \
  --plan artifacts/api-prod.plan.json \
  --approve <plan-digest>
```

`--approve` is required only when the plan contains a delete or replacement.
It must equal the saved plan's lowercase hexadecimal digest. Direct deploys
with destructive operations require `--confirm`; production automation should
prefer the digest-specific saved-plan path.

`destroy` continues to use `--confirm`. The executor, not an individual
provider, enforces the destructive confirmation gate.

## Protection Semantics

Resource lifecycle `protect` remains absolute:

- planning a protected delete fails with `ProtectedResource`;
- planning a protected replacement fails with `ProtectedResource`;
- neither `--confirm` nor `--approve` bypasses lifecycle protection;
- an operator must first deploy an explicit lifecycle change that removes
  protection, then create and approve a new destructive plan.

Plan approval is a second guard for destructive operations that are otherwise
allowed. This keeps CockroachDB and other protected data resources retained by
default while still supporting reviewed application cleanup.

## Saved Plan Format

Format v1 is deterministic JSON with these fields:

```text
schema                 = "ziac.saved-plan.v1"
format_version         = 1
created_at_millis      = unsigned integer
stack                  = selected stack
stage                  = selected stage
plan_digest            = lowercase SHA-256 hex
approval_required      = true when any operation deletes or replaces
preconditions          = lineage, serial, graph digest, operation digest
operations             = full immutable operation payloads
```

Each operation persists its kind, full desired resource node, dependencies,
and reasons. The resource node includes provider, type, schema version, logical
ID, canonical inputs, input hash, and lifecycle settings.

Secret values use only `Value.secret_ref` or `Value.output_ref`. The serializer
uses canonical `Value` JSON and has no API that accepts a secret payload.

## Plan Digest

The plan digest is SHA-256 over a framed binary transcript containing:

- a domain separator and format version;
- creation time, stack, and stage;
- lineage hash and state serial;
- desired graph and operation digests;
- the derived approval requirement.

The operation digest already covers the operation kind, complete canonical
resource data, dependencies, and reasons. Its resource input coverage is
hardened to include canonical input JSON, not only the stored input hash.

Changing any executable operation, target identity, precondition, or approval
classification changes the plan digest. The loader recomputes input hashes,
operation integrity, approval requirement, and the top-level plan digest.

## Immutability And File Safety

Plan creation uses exclusive file creation. Ziac refuses to overwrite an
existing artifact, preventing an approved path from silently changing under a
reviewer. Operators deliberately choose a new path for a new plan.

Parsing is strict and bounded:

- only format version 1 and the exact schema are accepted;
- required fields and enum names are validated;
- SHA-256 fields require exactly 64 lowercase hexadecimal characters;
- integer ranges and operation timeout bounds are checked;
- duplicate resource IDs and dependency cycles are rejected by scheduling;
- the file is limited to 64 MiB after read;
- malformed, future, or integrity-mismatched plans fail before provider access.

## Apply Flow

`deploy --plan` performs these steps:

1. Compile the selected stack and its comptime contracts.
2. Select the provider registry using that graph.
3. Acquire the state writer lease.
4. Load current state.
5. Load and integrity-check the saved plan.
6. Verify saved stack and stage equal CLI selection.
7. Hash the current compiled graph and compare it with the saved graph digest.
8. Verify the exact plan digest when destructive approval is required.
9. Execute the loaded operations without invoking either planner.
10. Checkpoint and save state and resolved outputs normally.

This intentionally compiles the current graph without recalculating
operations. It preserves comptime Env/provider/binding validation and rejects
changed desired code while guaranteeing that provider mutations match the
reviewed plan.

## Staleness And Failure Policy

Before provider access:

- lineage mismatch returns `PlanLineageMismatch`;
- state serial mismatch returns `StalePlan`;
- desired graph mismatch returns `PlanDesiredGraphMismatch`;
- operation or input mismatch returns `PlanIntegrityMismatch`;
- target mismatch returns `PlanTargetMismatch`;
- missing or wrong approval returns `PlanApprovalRequired` or
  `PlanApprovalMismatch`;
- missing confirmation returns `DestructiveConfirmationRequired`.

Failures never trigger replanning, unconditional state writes, or provider
fallbacks. The operator creates a new plan against current code and state.

## CLI Receipts

Stable JSON receipts move to `ziac.command.v2` and add:

- `plan_digest` as a string or null;
- `plan_path` as a string or null;
- `approval_required` as a boolean.

Human output prints the digest and approval requirement after saving a plan.
It never prints inputs, authorization data, or secret values.

## Acceptance Tests

- Save/load round trip preserves full operation semantics and preconditions.
- Existing plan paths are never overwritten.
- State serial and lineage changes reject before provider access.
- Current desired graph changes reject before provider access.
- Mutated operation inputs, hashes, dependencies, or top-level digest reject.
- Destructive saved plans require the exact digest.
- Direct destructive deploy and destroy require explicit confirmation.
- Lifecycle-protected resources remain unplannable.
- Sentinel secret plaintext is absent from serialized bytes and CLI receipts.
- Saved plan apply uses its loaded operations and never calls a planner.

