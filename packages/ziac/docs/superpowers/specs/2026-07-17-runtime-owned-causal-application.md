# Runtime-owned causal Ziac applications

## Objective

Make a canonical Ziac application an infrastructure program assembled from a
stack, providers, state, services and layers. Application authors must not
create, receive or forward a causal store and must not manually describe
runtime lifecycle events. The ZigEffect runtime records execution structure;
Ziac's reusable adapters add infrastructure semantics.

The canonical one-shot composition is:

```zig
const live = Ziac.Application.layer(.{
    .stack = &stack,
    .state = &state,
    .providers = providers,
});

var runtime = try zstd.ManagedRuntime(@TypeOf(live)).make(
    allocator,
    io,
    root,
    live,
    .{},
);
try Ziac.Application.run(&runtime);
```

The explicit state dependency remains because the current Ziac engine supports
caller-selected local and remote state authorities. It is infrastructure
composition, not observability plumbing. A later persistent `StateStore` layer
can replace it without changing the program.

## Ownership boundary

### ZigEffect runtime

- creates or accepts the bounded causal store;
- owns NenDB persistence, run/fiber/scope/layer topology, traces, metrics and
  logs;
- enriches record-only capabilities with the active run, effect, fiber, scope,
  trace and causal context;
- checks graph health and flushes before shutdown.

### Ziac framework

- turns plan, resource operation, provider method, retry, LRO, state commit,
  drift and workflow checkpoint boundaries into typed semantic facts;
- installs those adapters from `Application`, executor, provider and workflow
  entry points;
- preserves parent links so an agent can traverse from a plan to the committed
  state without reconstructing the path from log text.

### Ziac application

- declares resource/component intent and domain policy;
- supplies providers, state and other service layers;
- runs the composed program;
- contains no `recordCausal`, `causalRecorder`, `CausalStore`,
  `CausalJournalStore` or `causal_store` plumbing.

### Tests

Tests may inject a controlled causal store, inspect records and publish proof.
That is an explicit test harness boundary, not application architecture.

## Semantic model

Ziac uses one internal `RuntimeEvents` adapter. It holds a recording-only
runtime capability, never store ownership. The adapter emits stable
`span_recorded` facts with `ziac.*` semantic type names and typed constructors.
It is the only Ziac production module allowed to translate infrastructure
events into raw causal events.

For each executable operation the minimum successful path is:

```text
ziac.plan
  -> ziac.resource.operation
  -> ziac.provider.rpc
  -> ziac.retry or ziac.lro (when applicable)
  -> ziac.state.commit
```

The plan event is parented by the named application effect. Every following
event is parented by the preceding semantic event for that resource. Parallel
resources therefore form independent branches beneath the same plan instead of
contending for one global "last event".

Provider instrumentation belongs in the `Provider` adapter methods so in-
process fakes, first-party live providers and RPC-backed providers receive the
same semantics. The RPC server still runs each frame as a named child effect;
it does not ask provider executables to record startup or request facts.

State commits are emitted after state mutation and checkpoint success. Retry
facts are emitted only after the schedule accepts another attempt. LRO facts
are emitted when a provider returns a pending operation and when it is polled.
Failures retain the most recent successful causal parent.

## Workflow model

Workflow journals remain application dependencies. Causal journal decoration,
statechart decision recording and checkpoint facts move behind an effectful
Ziac workflow adapter. Generated event applications declare the workflow and
activities; they do not construct `CausalJournalStore` or access the runtime
store. Pure workflow functions remain available to deterministic unit tests.

## Process and scaffold policy

Process roots express startup, service composition and request/job loops with
named effects. Layer construction already records service provisioning and a
named effect already records request lifecycle; duplicating those facts in an
entry point is forbidden.

Ziac infrastructure control-plane programs use the `Application.layer`
pattern. `ziac init` workload templates use their domain root layer and the same
single `ManagedRuntime` rule; they do not misuse the infrastructure executor as
an HTTP or event-service facade. Generated tests inject a controlled store
through `ManagedRuntime.Options`, run the application program, inspect semantic
facts and require Testing v2 proof.

## Failure and shutdown semantics

Semantic recording is best-effort and can never turn a provider success into an
infrastructure failure. Durable graph backend failures are not ignored: the
managed runtime reports degraded health and fails checked shutdown. The
one-shot `Application.run` validates graph health and owns checked shutdown;
tests that need inspection run `Application.program()` and shut down after
publishing evidence.

## Acceptance contract

The migration is complete when:

1. the public `Ziac.Application.layer` and `run` facade executes a stack;
2. a controlled runtime proves the automatic plan-to-state semantic path;
3. `ExecuteOptions` and `WorkflowRuntime` expose no causal store;
4. production roots and generated application source contain no manual causal
   APIs;
5. the executor, provider, LRO/retry and workflow adapters retain semantic
   evidence;
6. Testing v2 receipts are complete and the mapped causal IDs are queryable in
   NenDB;
7. manifest, compatibility and generated-template contracts are current.
