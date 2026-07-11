# Ziac Agent-First Development Platform Design

Date: 2026-07-11
Status: validated for implementation

## Objective

Ziac is an infrastructure operating system for agents, not an IaC chatbot. The
agent model remains replaceable. Ziac owns deterministic intent, graph and
provider semantics, authority, simulation, evidence, approvals, execution,
recovery, verification, and handoff.

The complete loop is:

```text
intent -> compile -> preflight -> simulate -> approve -> deploy
       -> observe -> diagnose -> repair -> verify -> handoff
```

Every transition emits a bounded, versioned, redacted artifact. CLI, MCP,
Workbench, CI, Codex, Claude, and future agents consume the same kernel APIs.

## Development Loops

Ziac exposes three truthful loops from one stack declaration:

| Loop | Command | Runtime | Contract |
| --- | --- | --- | --- |
| Hot reload | `ziac dev` | local Zig process | sub-second target; cloud topology is adapted explicitly |
| Watch deploy | `ziac deploy --watch` | personal Cloud Run stage | immutable code-only revisions; measured control-plane latency |
| Governed deploy | `ziac deploy --plan` | staging/production | saved digest, capability and approval gates |

`dev` provisions or adopts durable dependencies once, runs the application
locally, watches declared source roots, builds into a fresh process, verifies
readiness, atomically switches a stable proxy, and drains the prior process. A
failed build or readiness check leaves the previous healthy process serving.

`deploy --watch` never injects mutable code into production containers. It
cross-compiles the Zig binary, computes a deterministic OCI delta against
cached base layers, pushes only missing blobs, creates an immutable image
manifest, updates the development Cloud Run service, verifies a tagged or
zero-traffic revision, then moves development traffic. Production remains a
normal saved-plan operation.

## Agent Contract

`ziac.project.json` owns:

- project identity, source roots, components, requirements, acceptance checks;
- environments and allowed providers/projects/regions;
- local, cloud, mock, proxy, skipped, and remote-only resource adaptations;
- SLO and cost budgets;
- deterministic test scenarios and live qualification requirements;
- authority defaults for read, plan, apply, destroy, secrets, and network use.

The parser rejects duplicate IDs, dangling references, path escape, unknown
adaptation kinds, impossible budgets, destructive auto-authority, and required
acceptance checks without scenarios.

## Capability And Autonomy

A capability envelope is explicit input to every agent mutation. It contains:

- stack, stage, provider and project allowlists;
- read, plan, apply, delete, secret-read and live-network permissions;
- maximum creates, updates, deletes, regions and estimated monthly delta;
- absolute deadline and expiry;
- exact saved-plan digest when apply is authorized;
- human-approval requirement.

The engine intersects the envelope with the project contract. It never expands
authority from ambient credentials. Expired, over-budget, project-mismatched,
destructive, or digest-mismatched actions stop before provider access.

## Agent Session State Machine

The durable state machine is:

```text
orienting -> planning -> preflighting -> simulating -> awaiting_approval
-> applying -> verifying -> complete
                       \-> diagnosing -> proposing_repair -> verifying
```

Terminal states are `complete`, `blocked`, `cancelled`, and `failed`. Every
transition requires an event ID and records requirement, resource, plan, and
evidence references. Invalid transitions are rejected and recovery resumes from
the last valid checkpoint.

## Agent Kernel

The public library and CLI support:

```text
ziac agent orient
ziac agent status
ziac agent next
ziac agent query --resource <id>
ziac agent explain --event <id>
ziac agent simulate --scenario <id>
ziac agent propose --out <saved-plan>
ziac agent verify --requirement <id>
ziac agent handoff
```

All commands support stable JSON. `next` reports declared actions and commands,
not generated shell. `propose` can create an immutable saved plan but cannot
apply it. `handoff` reports unsupported and unrun evidence honestly.

## Resource Adaptation

Each resource has an explicit development strategy:

```text
local_process   application executes as a supervised native process
local_service   bounded local implementation, such as Cockroach verified TLS
local_proxy     stable local representation of routing or ingress
cloud_read      real stage resource, read-only from the local process
cloud_resource  real personal-stage resource
mock            deterministic typed provider
skip            intentionally absent with recorded evidence
remote_only     cannot be qualified locally
```

Defaults are conservative. `ZigService` adapts to `local_process`; global load
balancing to `local_proxy`; DNS and certificates to `skip`; Cockroach to
`local_service`; Artifact Registry and Cloud Build to `skip`; stage secrets to
`cloud_read` only with secret authority; PSC and Direct VPC to `remote_only`.

The same comptime `App.Env` and binding graph remain authoritative. Secret
payloads are injected only into process memory and never enter events, plans,
receipts, source archives, or Workbench artifacts.

## Hot-Swap Runtime

The dev runtime separates a stable ingress proxy from application generations:

```text
public port -> dev proxy -> active generation
                         -> draining generation
```

A generation is content-addressed by source/build digest and owns an internal
port, process handle, start time, health state, and bounded logs. Promotion
requires successful startup and readiness probes. Promotion is atomic. The old
generation drains for a bounded grace period and is then terminated. Build,
spawn, probe, promotion, drain, and termination failures are typed events.

The runtime interfaces with filesystem, process, clock, HTTP probe, and proxy
services through injectable vtables. Deterministic tests exercise rapid saves,
stale-build cancellation, spawn failure, readiness failure, drain timeout,
rollback to the healthy generation, and clean shutdown. A native adapter drives
the actual CLI command.

## Incremental Change Classification

The watcher classifies an observed change before side effects:

```text
source_only -> local rebuild or fast remote image
image_only -> remote immutable revision
runtime_config -> targeted Cloud Run update
secret_reference -> restart locally or revision remotely
graph_topology -> affected-subgraph plan
destructive -> approval required
```

Existing resource input hashes and dependencies define the affected subgraph.
Unchanged infrastructure produces zero provider mutations. A newer save cancels
stale unpromoted work and converges to the newest digest.

## Unified Causal Logs

`ziac.log.v1` contains:

- session, event, parent and sequence identity;
- timestamp, source, stream, severity and lifecycle status;
- stack, stage, resource, region, revision, operation and RPC;
- trace/span/request/LRO identifiers;
- bounded message and structured fields;
- source reference, requirement and acceptance IDs;
- redaction and truncation evidence.

Sources include compiler, local process, dev proxy, provider, Cloud Run, load
balancer, Cockroach, health checks, tests, agent actions, and repair attempts.
The event store is bounded, deduplicated and ordered. It records dropped and
suppressed counts instead of pretending completeness.

`tail`, `logs`, and `explain` query this store. Cloud Logging initially uses
bounded `entries.list` cursor polling; `entries.tail` activates only after the
audited streaming gRPC adapter qualifies. Workbench receives the same event
stream and filters by resource, region, revision, trace and session.

## Deterministic Infrastructure Testing

The scenario kernel models:

- region loss and recovery;
- quota exhaustion and permission denial;
- stale etag and partial discovery;
- interrupted apply and LRO resume;
- Cockroach gateway/locality loss;
- secret rotation;
- failed build, process, readiness and proxy promotion;
- rollback and TTL cleanup.

Scenarios have stable seeds, bounds, replay tokens, expected findings, and
required verification. Unsupported live fidelity remains visible.

## OCI Delta And Watch Deploy

The OCI planner is pure and deterministic. Given a pinned base manifest and
Zig binary, it computes layer digest, config digest, manifest digest, blob
existence requests, upload plan and final image reference. Registry and Cloud
Run mutation are injectable providers with scripted tests.

Watch deploy uses a state machine with coalescing and cancellation. It refuses
production stages without an exact capability and saved-plan digest. It records
actual build, upload, revision, readiness and traffic timings; SLO misses are
evidence, not hidden retries.

## MCP And Skills

The MCP server is a thin adapter over the agent kernel. Initial tools are
read-only: status, graph query, evidence query, plan and simulation. Proposal,
verification and handoff follow. Apply accepts only a saved plan, exact digest
and capability envelope. There is no arbitrary shell tool and no separate MCP
state model.

Generated Codex and Claude skills teach the same workflow and command schemas.
They grant no authority.

## Ephemeral Environments

Preview sessions use repository-bound stage names, WIF identities, isolated GCS
state, cost/resource budgets, expiry and automatic cleanup. A lease records
owner, created time, expiry, heartbeat and retained evidence location. Cleanup
is idempotent and production-proof. Expired sessions cannot mutate resources;
cleanup authority is narrower than general apply authority.

## Closed-Loop Diagnosis

An investigation correlates application facts and infrastructure evidence:

```text
request failure -> revision -> deployment digest -> App.Env field
-> binding edge -> secret version -> runtime identity -> IAM
-> regional network/PSC -> Cockroach locality -> typed provider cause
```

The first acceptance case deliberately removes Secret Manager access from a
Cloud Run-to-Cockroach binding. Ziac must orient, identify the broken causal
edge, propose an IAM repair as a saved plan, verify budget/authority, simulate
the repaired graph, and produce a handoff without parsing terminal text.

## SLOs

- local save to healthy process: p50 <300 ms, p95 <1 s;
- local event visibility: <100 ms;
- code-only remote preview: measured target p50 <15 s, never guaranteed;
- cloud event visibility: target <2 s;
- unchanged infrastructure: zero provider mutations;
- failed reload: previous healthy generation remains available.

Performance tests record measured values. Deterministic tests prove budget
calculation but cannot claim real cloud latency.

## Non-Goals

- embedding a privileged model inside Ziac;
- mutable code injection into production containers;
- claiming complete local fidelity for PSC, Direct VPC or global routing;
- storing secret payloads or raw unbounded logs;
- allowing MCP or skills to bypass saved plans, capabilities or approvals;
- creating one-off report-about-report tools instead of runtime capabilities.

## Completion

M11-M16 are deterministically complete when the agent contract, dev runtime,
logs, OCI planner, scenario kernel, MCP adapter, ephemeral leases, Workbench
views and diagnosis acceptance all pass package and repository release gates.
Authenticated Cloud Run latency, log-tail, failover and Cockroach data-path
checks remain external qualification and must be reported separately.
