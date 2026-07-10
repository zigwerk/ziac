# Ziac Immutable Saved Plans Implementation Plan

Date: 2026-07-10

Design:
`docs/superpowers/specs/2026-07-10-ziac-saved-plans-design.md`

## Task 1: Harden Operation Integrity

Tests first:

- mutate canonical operation inputs without changing `inputs_hash`;
- assert executor rejects before provider access;
- assert equivalent canonical inputs retain stable digests.

Implementation:

- include canonical resource inputs in operation and desired-graph digests;
- expose desired graph digest calculation for saved-plan validation;
- add helpers for destructive operation classification.

Gate:

```sh
cd packages/ziac && zig build test
```

## Task 2: Add Saved Plan Format

Tests first:

- deterministic round trip of create, update, replacement, delete, references,
  lifecycle, dependencies, and reasons;
- strict schema/version/hash/enum/range validation;
- input, operation, approval, and top-level digest tamper detection;
- create-exclusive file behavior;
- secret plaintext sentinel scan.

Implementation:

- add `src/plan_format.zig`;
- serialize canonical full operation payloads;
- parse into an arena-owned `LoadedPlan`;
- recompute all integrity and derived fields;
- add bounded file save/load APIs.

Gate:

```sh
cd packages/ziac && zig build test
```

## Task 3: Enforce Destructive Approval

Tests first:

- executor rejects unconfirmed delete and replacement;
- executor permits confirmed destructive operations;
- lifecycle-protected delete/replacement remains rejected at planning;
- saved plan exact digest accepts, missing or wrong digest rejects.

Implementation:

- add executor-level destructive confirmation precondition;
- keep provider context propagation;
- add saved-plan approval validation using the plan digest.

Gate:

```sh
cd packages/ziac && zig build test
```

## Task 4: Integrate CLI

Tests first:

- `plan --out` writes a plan and reports digest/approval in human and JSON
  output;
- `deploy --plan` applies without replanning;
- target, state, desired graph, and approval mismatches fail before provider
  mutation;
- direct destructive deploy and destroy require `--confirm`;
- normal non-destructive deploy remains unchanged.

Implementation:

- add plan/deploy option sets and parsed arguments;
- add an optional plan file store to CLI `Env` and wire local files in `main`;
- select loaded or ephemeral plan ownership safely;
- validate current desired graph before execution;
- extend command receipts to `ziac.command.v2`.

Gate:

```sh
cd packages/ziac && zig build test
cd packages/ziac && zig build examples
cd packages/ziac && zig build
```

## Task 5: Document And Release

- add `packages/ziac/docs/saved-plans.md`;
- update README, architecture, roadmap, and end-to-end delivery evidence;
- run package, repository, PostgreSQL/Cockroach, formatting, hygiene, and diff
  gates;
- commit as `Add immutable Ziac saved plans`.

