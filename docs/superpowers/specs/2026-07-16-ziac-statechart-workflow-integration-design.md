# Ziac Statechart and Durable Workflow Integration

**Date:** 2026-07-16
**Status:** validated for implementation

## Problem

Ziac has explicit control-flow state in rollout, watch deployment, provider
long-running operations, leases, estate scans, billing ingestion, checkpoints,
and workers. Today those flows are mostly synchronous functions and mutable
records. They emit some causal facts, but they do not use ZigEffect's typed
statechart decisions, durable workflow journals, activity idempotency, replay,
timers, signals, control plane, or fleet inspection.

Generated projects also reserve `.zigeffect/statecharts` without establishing
how infrastructure workflows participate in their root runtime and causal
graph.

## Decision

Use the existing ZigEffect engines as two complementary layers:

- A typed finite statechart is the pure control-flow authority. Its context is
  owned value data; actions emit typed commands and never perform I/O.
- A durable ZigEffect workflow journal is the execution authority for emitted
  commands. Each command is an idempotent workflow activity with a stable key.
- The process-level `ManagedRuntime` owns causal recording and embedded NenDB.
  Workflow journal events and statechart decisions enter that same recorder.
- A crash-safe `FileJournalStore` is opened once for a Ziac process. Replaying
  an execution reconstructs the statechart from recorded activity outcomes;
  completed cloud mutations are never invoked again.
- Workflow identity derives from the machine id and immutable saved-plan
  digest. No secret or raw provider response enters the journal or graph.

The first complete slice is watch deployment because it already has a bounded
four-phase protocol and a live implementation. Its states are `pending`,
`pushing`, `creating_revision`, `waiting_ready`, `promoting_traffic`,
`complete`, and `failed`. Its commands are image push, zero-traffic revision
creation, readiness proof, and traffic promotion.

## Execution model

1. Validate development-stage, immutable-image, saved-plan, project, region,
   cost, and apply authority before creating a workflow execution.
2. Append an idempotent `workflow_started` event.
3. Step the typed statechart with `start`; record the decision causally.
4. Execute its one bounded command through `WorkflowContext.activity`.
5. Feed the typed success/failure event into the machine and record the next
   decision. Continue until a terminal state.
6. Append one idempotent `workflow_completed` or `workflow_failed` event.
7. Derive the existing stable watch-deploy receipt from terminal machine
   context. Existing log projections remain projections, not authority.

If the process exits after an activity receipt but before the next transition,
the next run reconstructs the machine from the beginning. `WorkflowContext`
returns the recorded activity result/failure, so the external operation is not
repeated and the statechart converges to the same terminal snapshot.

## Public boundaries

`watch_deploy.executeWorkflow` receives a `WorkflowRuntime` containing a ZigEffect
`JournalStore`, the runtime-owned `CausalStore`, and optional run lineage. Ziac's
CLI opens the file journal below `.zigeffect/workflows/ziac-watch-deploy`;
deterministic unit tests use `InMemoryJournalStore`, while the acceptance test
closes and reopens `FileJournalStore`.

The machine is registered through the standard-library statechart catalog.
Registration is locked, atomic, idempotent, preserves unrelated machines, and
publishes native, XState, Mermaid, and DOT projections. Reusing one id/version
with a changed fingerprint fails closed.

This slice deliberately does not place runtime handles, allocators, provider
clients, or strings in statechart context. Those remain in the activity
adapter. The same separation will be reused for provider LRO, lease, estate,
and billing machines.

## Causal and agent contract

Every transition emits `statechart_event_recorded` with machine fingerprint,
instance, selected transition, previous/next state, revision, actions, and
command count. Every activity and terminal workflow event emits
`workflow_event_recorded` with workflow/execution identity and parent sequence.
Both are exported through the owning runtime into NenDB.

Agents must be able to start from either terminal workflow event or transition,
follow its parents, identify the saved-plan execution, and distinguish a failed
phase from a denied capability or runtime defect without reading terminal text.

## Failure and recovery invariants

- Traffic promotion is unreachable until readiness succeeds.
- A completed activity is not called again during replay.
- Activity failures select an explicit terminal failure transition.
- Workflow and statechart bounds are finite and checked.
- Event and activity identities are stable and idempotent.
- Journal corruption and future schema versions fail closed.
- Causal evidence contains no plan content, image credentials, provider
  payloads, or raw errors.
- No runtime, fiber, or workflow journal is created by a library hidden from
  its caller.

## Follow-on machines

After the rollout slice is proven, apply the same seam in this order:

1. provider long-running-operation polling and cancellation;
2. lease expiry, heartbeat, cleanup, and retry;
3. estate page scan and incremental persistence;
4. billing query, attribution batches, and persistence;
5. full provider operation read/diff/mutate/checkpoint lifecycle.

Those remain separate machines with separate journals, authority, bounds, and
tests. They must not be collapsed into one infrastructure mega-workflow.
