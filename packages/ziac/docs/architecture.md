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
