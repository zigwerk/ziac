# Statecharts And Durable Workflows

Ziac uses finite statecharts and durable workflows for different jobs. A
statechart is the pure authority for which transition is legal and which typed
command comes next. A workflow is the durable authority for performing that
command once, recording its result, and replaying it after restart.

Do not put cloud clients, files, allocators, runtime handles, credentials, or
network responses in statechart context. Context is bounded value data. Actions
only update that value data and emit typed commands. External work belongs in a
`WorkflowContext.activity` behind a service supplied by the application's root
layer.

## Application composition

One process owns one `ManagedRuntime`. The root layer provides domain services
and workflow services. A process-level `FileJournalStore` is opened before the
runtime, passed into the workflow service, and released after the runtime. The
runtime's causal recorder wraps journal writes and records every statechart
decision, so workflow and machine facts enter the same embedded NenDB graph as
effects, layers, scopes, logs, traces, and provider boundaries.

The statechart decision produced from an activity result is parented to that
activity's latest durable causal event. This joins both models into one
traversable graph rather than leaving agents to correlate unrelated streams by
timestamp.

Every durable activity needs:

- a stable semantic name;
- an idempotency key derived from immutable execution identity;
- bounded payload and result codecs;
- a typed failure set;
- an external adapter supplied through a service; and
- a deterministic test fake.

On restart, rebuild the pure statechart from its initial state and feed it the
recorded activity results. `WorkflowContext` returns completed results or
failures from the journal instead of invoking the adapter again. The machine
therefore converges to the same terminal state without repeating a cloud
mutation, acknowledgement, payment, or other external effect.

## Project and agent inspection

Register application machines with
`zstd.Statechart.registerDefinitionAtomic`. Registration preserves unrelated
catalog entries, is idempotent for an identical id and version, exports native,
XState, Mermaid, and DOT projections, and fails if changed structure reuses a
released version.

```sh
zigeffect statechart list --json
zigeffect statechart show ziac.watch-deploy --json
zigeffect statechart export ziac.watch-deploy --format mermaid
zigeffect graph status --json
zigeffect graph since <event-id> --json
```

The catalog is the definition and visualization surface. NenDB is the live
causal execution surface. Agents should inspect both before a change, run the
requirement-owned scenario, then compare graph records after the change. A
terminal workflow event identifies the execution; its causal parents expose
activities and statechart decisions without requiring raw terminal output.

## Shipped Ziac machine

`ziac.watch-deploy` controls immutable development deployments with the states
`pending`, `pushing`, `creating_revision`, `waiting_ready`,
`promoting_traffic`, `complete`, and `failed`. Image push, zero-traffic revision
creation, readiness, and traffic promotion are durable activities. The CLI
uses a locked, fsynced journal at
`.zigeffect/workflows/ziac-watch-deploy`; the runtime-owned causal recorder
automatically projects its journal and decisions into NenDB.

The official `event-driven-zig` template applies the same pattern to event
validation, persistence, and acknowledgement. It generates an `EventWorkflow`
service, typed machine, durable file journal, catalog registration, deterministic
adapter, manifest requirement, and Testing v2 replay scenario.

## Migration order

Keep control flows as separate bounded machines rather than creating one
infrastructure mega-workflow. The next Ziac migrations are:

1. provider long-running-operation polling and cancellation;
2. lease expiry, heartbeat, cleanup, and retry;
3. estate paging and incremental persistence;
4. billing query, attribution batches, and persistence; and
5. provider read, diff, mutate, checkpoint, and recovery lifecycle.

Each migration requires a manifest-owned scenario, a red deterministic test,
journal reopen or replay evidence, causal transition and activity assertions,
and complete Testing v2 receipts.
