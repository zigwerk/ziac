# Ziac Canonical ZigEffect Composition Roadmap

**Audited and implemented:** 2026-07-16
**Status:** the canonical runtime foundation, external tags, plan/execute
effects, process roots, durable NenDB graph, project intent, and generated
application roots are implemented. Command adapters and provider/state
lifecycle are intentionally tracked as the remaining migration rather than
being misrepresented as complete.

| Surface | Status | Use for new Ziac composition? |
| --- | --- | --- |
| `fx.kernel.Service`, `Effect`, `Layer`, `ManagedRuntime` | Canonical foundation | Yes |
| `zstd.FileSystem`, `Process`, Config, Console canonical operations | Z0 available | Yes |
| `cli.Env` adapter record and legacy executor combinator | Transitional internals | No new use |
| Canonical ProjectCompiler, StateStore, ProviderRegistry, ProcessSpawner tags | Implemented | Yes |
| Canonical plan/execute Effects and root layer | Implemented | Yes |
| Scoped provider-process and state-backend layers | Pending Z2-Z3 | Not yet complete |

## Finding

Ziac now starts every shipped executable through `src/process_runtime.zig`.
The CLI's canonical graph is `.zigeffect/graph`; other long-lived process
graphs are isolated under `.zigeffect/graphs/<process>` because the embedded
database deliberately holds an exclusive process lock. `zigeffect graph ...`
therefore gives agents a stable default view of command execution without
allowing multiple daemons to corrupt one WAL.

`src/application.zig` defines the stable external tags and canonical
requirements-typed plan/execute effects. `executor.executePlan` no longer
constructs a nested runtime: bounded parallel operations execute in the owning
command scope with the caller's fiber executor and causal recorder.

The resource model should not be rewritten. Typed declarations, graph
validation, hashes, binding resolution, diff calculation, operation ordering,
saved-plan validation, value/state formats, cost calculation, and diagnostic
formatting remain ordinary deterministic Zig.

## Canonical Boundaries

Services represent substitutable external capabilities, not every module:

- `ziac/ProjectCompiler` — compile/load a project program;
- `ziac/StateStore` — state read/write/checkpoint operations;
- `ziac/ProviderRegistry` — resolve already-acquired provider clients;
- `ziac/ProcessSpawner` and `zstd/FileSystem` — platform boundaries;
- `ziac/DevHost` and `ziac/DashboardHost` — long-lived session capabilities.

Planning remains a pure function after desired graph, observed state, and
provider observations are available. Execution is normally an effect
constructor requiring StateStore and ProviderRegistry; it becomes a service
only where an actually substitutable scheduling policy justifies one.

CLI, MCP, dashboard, worker, and agent adapters decode requests, select the
same command effects, and render typed/redacted results. They do not implement
parallel plan/apply paths.

## Lifetime Model

### One-shot commands

`ziac check`, `plan`, `deploy`, `destroy`, `refresh`, and `import` create one
ManagedRuntime for the process. Provider processes and state clients live for
that invocation. The selected command is one child run.

### Daemon/session commands

`ziac dev`, dashboard host, MCP server, estate control plane, and billing worker
create one ManagedRuntime for the whole process/session. Watch events, HTTP/MCP
requests, jobs, and messages run through requirements-limited RuntimeHandles in
fresh child scopes.

### Command locks

State clients are application-scoped. Exclusive stack/stage locks are
command-scoped resources. A one-shot command naturally holds its lock for the
full command run. A daemon must acquire and release a lock inside each mutating
child run; it must never retain a deployment lock for the daemon lifetime.

### Provider processes

Provider RPC processes are scoped layers. Acquisition spawns and verifies the
`ziac.provider.rpc.v1` handshake; use reuses the bounded client across retries
and concurrent operations; finalization drains RPC, terminates, waits, and
closes pipes. The wire protocol and independent provider qualification boundary
do not change.

## Target Composition

```text
std defaults + filesystem/process layers
                 |
 state-client layer + provider-process layers + project compiler layer
                 |
            process MainLayer
                 |
             ManagedRuntime
                 |
 CLI / MCP / dashboard / worker request -> command Effect -> child scopes
                 |
      pure plan + effectful refresh/execute/checkpoint
```

## Ordered Gates

### Z0 — Kernel and std admission

Require the canonical kernel, runtime aspects/defaults, RuntimeHandle server/
worker oracle, and migrated std FileSystem/Process/Config/Console surfaces.
Ziac must not build new code on the legacy provider tuple during this wait.

**Current:** complete. The kernel, managed runtime, runtime handle, application
snapshot, runtime defaults/aspects, and FileSystem/Process migration oracles are
available. Z1 may begin without extending the legacy prototype.

### Z1 — Canonical external tags

Define stable ProjectCompiler, StateStore, ProviderRegistry, ProcessSpawner,
and session-host tags. Add live and deterministic layers with exact
Output/Error/Input types. Remove the prototype Planner/Executor service pattern
where it only wraps pure functions.

**Current:** complete for the engine surface. The four stable tags and their
operations are visible through the application snapshot and tested through one
durable managed runtime.

### Z2 — State and command scope

Move local/GCS/Cockroach state clients into application-scoped layers. Model
exclusive locks, checkpoints, cancellation, authority, and command diagnostics
as child-scope resources/effects. Prove release on typed failure,
interruption, defect, and failed checkpoint.

**Current:** in progress. Canonical `StateStore` exists and command execution
shares the owning recorder, but local/GCS/Cockroach adapter acquisition and
exclusive locks still live behind the transitional CLI adapter record.

### Z3 — Provider lifecycle

Move first-party and RPC providers into scoped layers. Keep processes alive
across all operations in one command/session, retries, and concurrent fibers.
Close only after operation fibers join and terminal checkpoints complete.

**Current:** in progress. Provider executables have canonical process runtimes
and executor operations share their caller runtime. Turning every provider RPC
client into a memoized scoped layer remains open.

### Z4 — Command effects

Implement check, plan, deploy, destroy, refresh, import, unlock, rollback, and
outputs as requirement-typed effects. Remove the standalone executor runtime;
parallel work uses the current RuntimeHandle/fiber executor and nested operation
scopes.

**Current:** plan and execute are canonical Effects; the standalone executor
runtime has been deleted. The remaining CLI commands still need thin
requirements-typed constructors over the same pure command functions.

### Z5 — Shared adapters

Make CLI, MCP, dashboard, and agent tools call the same command effects.
Arguments/requests and receipts remain adapter data. Bounded redacted progress
comes from runtime aspects and semantic causal facts, not parallel mutable
status implementations.

**Current:** partial. All process roots share the runtime bootstrap and causal
contract, but CLI, MCP, dashboard, and agent request decoding do not yet all
dispatch the same command Effect constructors.

### Z6 — Daemon and worker roots

Migrate dev/watch, dashboard host, MCP, estate control plane, billing worker,
log tails, proxies, and agent sessions. Each process owns one runtime; each
event/request/job gets a child run scope; SIGTERM drains supervised work before
disposing providers, sockets, and state clients.

**Current:** process-root and request-scope migration complete for estate and
billing HTTP connections, MCP messages, provider-RPC frames, and dashboard
bridge calls. Signal-driven draining and the dashboard workspace-observer
thread remain the next lifecycle-hardening slice.

### Z7 — Generated application roots

Templates generate std service tags/layers, one application root layer, and one
ManagedRuntime. Ziac infrastructure resources/components remain pure typed
graph compilers and never become runtime services.

**Current:** complete. Both `ziac init` and registry application templates emit
`zigeffect.project.json`, compatibility metadata, typed service/layer code, one
managed runtime, Testing v2 causal acceptance evidence, and direct ZigEffect
dependency paths. Pure infrastructure-only templates stay pure.

### Z8 — Legacy deletion

Delete `cli.Env`, `application.EffectEnv`, provider tuples, standalone
`Runtime(ExecutionEnvironment)`, and legacy layer graphs. Keep provider RPC and
state schemas stable unless a separately qualified change requires migration.

**Current:** nested runtimes, the prototype application environment, and
production legacy layer graphs are removed. `cli.Env` and the executor's
proven structured parallel combinator remain until Z2-Z5 replace their adapter
surfaces.

### Z9 — Inspectable durable control flow

Use pure typed statecharts for bounded long-lived decisions and durable
workflow activities for external work. Register machine definitions in the
project catalog and record decisions plus journal events into the owning
runtime's NenDB graph. Keep graph compilation and plan derivation pure.

**Current:** the immutable watch deployment is migrated end to end with a
fsynced CLI journal, stable activity keys, replay after journal reopen, typed
terminal failures, catalog projections, and causal acceptance evidence. The
official event-driven template generates the same composition pattern. Provider
LRO, leases, estate, billing, and the full provider-operation lifecycle remain
the ordered follow-on machines documented in `statecharts-and-workflows.md`.

## Safety and Evidence Gates

- Source-safety adoption is deliberately incremental. The canonical
  composition acceptance test is in the strict agent-safe zone; the application
  service adapter and managed process boundary have exact, line-fingerprinted
  audited allowances. Existing command, provider, dashboard, state, and
  transport internals remain a declared migration surface: Debug/ReleaseSafe,
  allocation, leak, causal, schedule, and executor gates cover them now, but
  they enter static safety roots only as each slice is converted and reviewed.
- The migration grants no apply, delete, secret-read, live-network, project,
  region, or cost authority.
- The current project manifest remains the executable intent owner for
  `zigeffect-composable-control-plane`.
- Provider protocol qualification remains separate from Ziac-side composition.
- Required scenarios use deterministic fake providers and Testing v2 receipts.
- Run package-native tests and `ziac project check --agent --json`; incomplete,
  stale, credential-gated, or truncated evidence is not a pass.
- Authenticated cloud evidence is required only when provider behavior changes.

## Definition of Done

- no mega-environment or legacy Context/Effect/Layer/Runtime in Ziac roots;
- pure graph/plan logic remains independent of the runtime;
- providers and state clients have application/session ownership;
- locks and operation resources have command/operation ownership;
- one runtime per process and one child run per request/job/command;
- CLI/MCP/dashboard/worker paths share command effects;
- causal evidence is structural by default and semantic at domain boundaries;
  and
- all manifest checks and Testing v2 receipts are complete and clean.
