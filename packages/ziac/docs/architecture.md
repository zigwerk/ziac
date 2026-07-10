# Ziac Architecture

Ziac is a separate package from zigeffect. zigeffect provides effects, layers,
structured concurrency, scopes, and causal traces. zigeffect-std provides the
application-facing standard library facade that Ziac imports as its substrate.

Ziac provides the IaC product layer: stacks, resources, outputs, providers,
state, plans, applies, and component libraries.

Initial source domains:

- `core.zig`: names, IDs, physical names, diagnostics.
- `output.zig`: lazy outputs and secret references.
- `resource.zig`: resource graph and dependency validation.
- `state.zig`: resource state records and in-memory store.
- `plan.zig`: deterministic plan operations.
- `provider.zig`: provider lifecycle vtable and fake provider.
- `apply.zig`: one-operation lifecycle and state transitions.
- `executor.zig`: stable dependency levels, bounded zigeffect execution, retry,
  deadlines, cancellation, and causal operation facts.
- `checkpoint.zig`: serialized state checkpoint interface and local-state
  adapter.
- `refresh.zig`: read-only provider refresh into observed state.
- `importer.zig`: validated adoption of existing provider resources.

Provider implementations must sit behind the provider lifecycle interface so the
engine can be tested without live cloud credentials. Every provider operation
receives an `OperationContext` containing its allocator, clock, absolute
deadline, and cooperative cancellation handle. Providers must not retain the
context after returning.

Plans own sorted dependency IDs for every operation. Apply phases execute
dependencies before consumers; destroy phases reverse that relationship.
Independent operations in one topological level are split into deterministic
batches and handed to zigeffect's structured `forEachPar` primitive. State and
the fake remote provider protect concurrent mutations with zigeffect spinlocks.

Each completed provider mutation checkpoints a deep, serial-consistent state
snapshot. Local resources and outputs use temporary-file replacement so a failed
write cannot truncate the previous state. Pending provider results retain their
operation handles and transitional status. On the next run the executor reads
the remote before applying: matching remote objects are adopted, absent objects
with live handles remain pending, and absent operations without handles resume
from the recovery plan. A refreshed noop with no local record is also re-read and
adopted, covering remote success immediately before a local crash.

Local writers coordinate through an exclusive `lock.json` per stack and stage.
Lock metadata records lineage, owner, command, and acquisition time. Inspection
is side-effect free, ordinary release checks owner identity, and forced unlock
checks lineage unless an explicit override is supplied. The CLI exposes
`refresh`, `import`, and `unlock`, and all commands can emit a versioned
`ziac.command.v1` JSON receipt.

Every plan captures the state lineage hash, state serial, canonical desired graph
digest, and an operation-integrity digest. The executor validates all four before
refresh, resume, or provider access. Resource and dependency insertion order do
not affect the desired graph digest, while any mutation of saved operation data
invalidates the operation digest.

Provider output descriptors carry their field name, Zig value type, and secrecy
at comptime. Resource builders expose typed references instead of predicting
provider-assigned values. Binding a reference to a consumer derives one
deduplicated graph edge. After mutation, references resolve from typed provider
outputs in state; stack output files and CLI output therefore use observed values
rather than builder-side URL conventions.
