# Ziac Canonical Runtime Hardening Design

**Date:** 2026-07-16
**Status:** validated for implementation

## Objective

Make every shipped Ziac application and generated application use the canonical
ZigEffect development model: typed service tags, composed layers, one managed
runtime per process, fresh child runs per command/request/job, automatic bounded
causal recording into an embedded NenDB graph, and Testing v2 evidence whose
semantic assertion IDs can be mapped to durable graph IDs.

The infrastructure declaration engine remains pure Zig. Resource declarations,
graph validation, binding resolution, hashing, planning, program encoding,
provider diffing, and cost calculation do not become services merely to appear
effectful.

## Audit Findings

- `packages/ziac/src/main.zig` provides one `cli.Env` mega-environment through
  the legacy layer graph and owns a detached in-memory causal store.
- `packages/ziac/src/executor.zig` creates a second legacy runtime for each plan
  execution.
- MCP, dashboard, GCP provider, Cockroach provider, estate-control-plane, and
  billing-worker executables have no ZigEffect runtime.
- the root `ziac.project.json` has requirements but no project compiler, so the
  documented `ziac check` command fails before it can inspect the graph;
- the base scaffold and registry templates generate ordinary Zig executables,
  not composed ZigEffect applications;
- generated tests use the Testing v2 runner but do not create `TestContext`
  evidence, share its causal store with the application runtime, or map runtime
  IDs to durable graph IDs;
- `ziac-gcpx` is correctly a pure component compiler and should not acquire a
  runtime.

## Architecture

### Pure declaration plane

`ziac-gcpx`, resource types, components, graph validation, planning, and program
encoding remain deterministic pure functions. Their tests run through Testing
v2, but the code itself does not depend on runtime services.

### Process runtime

Every executable process owns exactly one `zstd.ManagedRuntime`. A shared Ziac
process-root helper creates the runtime, installs the embedded NenDB graph,
records process start/completion facts, runs the supplied canonical effect, and
checks causal health before shutdown. The primary CLI writes the
manifest-addressable `.zigeffect/graph` so agents can use one standard query
surface. Other binaries receive a stable path under
`.zigeffect/graphs/<process>` so independently running providers and daemons
do not race on the exclusively locked WAL.

One-shot commands run once in the process runtime. Daemons use a runtime handle
for each request, protocol message, watch event, or job so layers are not rebuilt
and each unit of work has a fresh child scope.

### Control-plane services

The canonical tags are external capabilities, not wrappers around pure modules:

- `ziac/ProjectCompiler` resolves a compiled stack program;
- `ziac/StateStore` owns the selected local, GCS, or Cockroach state boundary;
- `ziac/ProviderRegistry` resolves already-acquired providers;
- `ziac/ProcessSpawner` owns bounded provider and verification processes;
- daemon-specific host tags own HTTP, stdio, dashboard, and worker lifetimes.

The first migration removes `Planner` as a service because planning is pure.
Command adapters may temporarily assemble their existing bounded request data,
but the runtime registry must expose the external capabilities individually and
must not register `cli.Env` as a service.

### Execution

Execution uses the process runtime rather than constructing another runtime.
Independent operations remain bounded and structured: every child operation is
run through a requirements-limited runtime handle, all children are joined, and
the command scope closes only after terminal checkpoints. Provider processes and
state clients remain application scoped; stack locks and operation contexts are
command/operation scoped.

### Generated projects

The base scaffold and every application template generate:

- `ziac.project.json` for infrastructure intent;
- `zigeffect.project.json` for application requirements and agent testing;
- typed application services and a root layer;
- one `zstd.ManagedRuntime` entry point with automatic causal graph ownership;
- a Testing v2 acceptance scenario using `TestContext`, the same caller-owned
  causal store as the runtime, semantic assertions, durable ID mapping while the
  runtime is live, runtime shutdown, and receipt publication.

Infrastructure-only templates such as Hermes keep pure graph compiler code but
their test artifact still publishes structured Testing v2 evidence.

## Agent Workflow

For a generated application an agent runs, in order:

1. `zigeffect compatibility --json` and `zigeffect project validate --json`;
2. `zigeffect agent status --json` and `zigeffect test list --json`;
3. the affected scenario through `zigeffect test affected` or `test run`;
4. graph queries using only `graph_durable` assertion IDs from the receipt;
5. `ziac check` and `ziac plan` for the infrastructure program;
6. coverage/gap checks and a handoff receipt.

Runtime-local IDs are never presented as directly queryable durable IDs. Multi-
process graphs are identified by process path and correlated through semantic
boundary, trace, resource, and deployment identities.

## Safety

- no apply, delete, live-network, secret-read, project, region, or cost authority
  is added;
- provider RPC wire contracts and provider resource behavior are unchanged;
- graph writes are bounded and redacted, and graph health is checked at shutdown;
- a failed graph write or incomplete Testing v2 receipt is a failed gate;
- authenticated cloud qualification remains separate.

## Acceptance

- no production Ziac root uses `fx.Runtime`, `layerGraph`, or a detached
  `CausalStore`;
- every shipped process root is owned by `zstd.ManagedRuntime`;
- the root Ziac project passes its documented check/plan workflow;
- every scaffold/template app compiles in Debug and ReleaseSafe and publishes a
  complete Testing v2 receipt;
- generated causal assertions map to queryable embedded NenDB records;
- all Ziac, gcpx, template, dashboard, provider RPC, architecture, and migration
  gates pass with complete receipts and zero pending tests, leaks, or log errors.
