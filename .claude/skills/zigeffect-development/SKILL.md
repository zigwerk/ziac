---
name: zigeffect-development
description: Build, change, debug, test, or review ZigEffect applications, services, libraries, packages, and framework code that use zigeffect, zigeffect-std, zigeffect.project.json, zstd.Testing, causal evidence, statecharts, or the zigeffect CLI. Use for requirements-driven application development, deterministic testing, runtime diagnosis, and evidence-backed agent handoffs.
---

# ZigEffect Development

Build from declared intent and structured runtime evidence. Use terminal text as
a bounded diagnostic artifact, not as the source of truth.

## Choose the operating mode

- **Application mode:** A `zigeffect.project.json` exists at the project root.
  The manifest owns requirements, components, commands, acceptance checks, test
  scenarios, safety policy, and executable authority.
- **Framework mode:** Work changes ZigEffect itself and no application manifest
  exists at the current root. Do not invent or bypass a manifest. Read the
  affected package's public exports and `build.zig`, run package-native Zig
  gates, and update generated templates and compatibility snapshots when their
  public contract changes.

## Run the proof-carrying causal loop

1. Orient with `zigeffect agent context --task <id-or-summary> --budget 65536
   --json`. Retain its source identity, manifest digest, graph cursor,
   authority, omissions, affected scenarios, and proof references.
2. Bind the request to a requirement, acceptance check, component, scenario,
   and fixed command. State the expected before/action/after causal path and the
   slice that must remain unchanged.
3. If a coordinator supplies a work packet, obey its baseline, allowed and
   excluded paths, dependencies, verification commands, graph cursor, lease,
   and fencing token. Never invent missing coordination or authority.
4. Add the failing deterministic native scenario, then make the smallest typed
   service/layer change through the one managed runtime.
5. Run the affected scenario. Treat
   `.zigeffect/tests/process-receipts/<scenario>.json` and
   `.zigeffect/handoffs/tests/<scenario>.json` as authoritative only when their
   source, manifest, command, toolchain, and completeness identities match.
   `.zigeffect/tests/raw-receipts/` and terminal output are diagnostic only.
6. Compare `zigeffect graph since <cursor> --limit 256 --json` with the
   counterfactual. Use `zigeffect graph path <from> <to> --limit 128 --json`
   for exact relationships.
7. Re-query `agent context` after the change. Reject stale proofs, undeclared or
   overlapping paths, expired fencing tokens, missing dependency proofs, and
   required gaps before integration.
8. Run project gates and hand off exact receipt/proof paths, replay commands,
   causal IDs, limitations, and any remaining authority requirement.

## Establish the application contract

Before editing application behavior:

1. Run `zigeffect compatibility --json` and read `zigeffect.project.json`.
   Inspect migrations with `zigeffect upgrade --dry-run --json`; never rewrite
   around a reported conflict.
2. After the context query, run `zigeffect compatibility --json`, `zigeffect
   project validate --json`, `zigeffect agent status --json`, `zigeffect agent
   next --json`, and `zigeffect test list --json`.
3. Map the user's request to a requirement, acceptance check, component,
   manifest-owned command, and one or more `test_scenarios`. Add missing intent
   to the manifest before implementing code.
4. Read the component's public facade, service layers, schemas, existing tests,
   and causal helpers. Do not infer a boundary from filenames alone.
5. Ask for user direction only when the missing requirement or authority would
   materially change behavior. Treat invalid, unsupported, or conflicting
   contracts as blocking evidence.

## Implement through public boundaries

- Import framework capabilities through `zigeffect_std` and application code
  through component public facades. Do not reach into another component's
  internals.
- Compose new applications with `zstd.fx.kernel.Service`, `Effect`, `Layer`,
  and one process-level `zstd.ManagedRuntime`. It automatically owns the
  bounded in-memory recorder, embedded NenDB topology, durable property WAL,
  agent map, and checked shutdown. Libraries export effects, service tags, and
  default layers; they do not hide an independent runtime. The lower-level
  `zstd.fx.kernel.ManagedRuntime` is only an explicit framework-test or embedded
  memory-only choice. Domain operations return descriptions; only the process
  root or a runtime-backed transport interprets them. Do not introduce
  `EffectEnv`, `ServiceEnv`, provider tuples, `LayerGraphEnv`, `layerGraph`,
  `ctx.runEffect`, direct `runIn` calls, per-endpoint runtimes, or manual causal
  store/backend wiring.
- In deterministic application acceptance tests, pass
  `context.causalStore()` only at the canonical `zstd.ManagedRuntime` root.
  Record semantic assertions against that execution, call
  `context.mapCausalEventIds(&runtime)` while the runtime is live, then shut
  down and publish. This produces graph-durable assertion IDs without a second
  runtime or a detached test graph. Mount the runtime at the owning project or
  component root. Query the project-mounted graph for at least one mapped ID
  before publishing; an ID in a temporary graph is not CLI-queryable proof.
- Model fallible work with typed effects, service layers, Schema, typed errors,
  scoped resources, and deterministic providers for config, clock, filesystem,
  process, HTTP, SQL, IDs, logging, and tracing.
- Use `zigeffect add` and `zigeffect generate` for conventional structure before
  hand-writing framework wiring.
- Emit semantic application facts at CLI, config, schema, HTTP, SQL, process,
  dependency, artifact, workflow, statechart, and acceptance boundaries. Attach
  domain references and causal parents when they help an agent locate a fault.
- Use typed statecharts for inspectable long-lived control flow and durable
  statecharts for replayable workflows. Keep pure decisions separate from
  effectful commands.
- Never put tokens, passwords, credential-bearing URLs, personal data, or raw
  terminal scrollback in manifests, facts, receipts, fixtures, snapshots, or
  Workbench payloads.

## Build gRPC and Cloud Run services

For canonical Yachdee backend communication, use `zigeffect-grpc` through the
`zigeffect_std.Grpc` facade. Native gRPC is the trusted service-to-service
boundary. SolidJS applications use generated Connect/Protobuf clients with
TanStack Solid Query; browser code never receives native service credentials.

1. Begin with the checked-in `.proto` contract. Preserve published field
   numbers and regenerate both Zig and Protobuf-ES outputs. Never treat generated
   files as independent schemas.
2. Run `zig build gen-proto`, `zig build schema-compatibility-test`, and
   `bunx @bufbuild/buf generate` from `packages/zigeffect-grpc` when the contract
   changes. Buf breaking compatibility must include the immutable baseline and
   negative fixture.
3. Define the implementation as a stable service tag. Register generated
   method effects with `Typed.generatedRoutesLayer`, own unary/streaming/
   incremental registries with their scoped layers, and compose
   `nativeServerLayer` into the application root. Generated libraries export
   bindings and layers; they never construct a runtime.
4. Use `Grpc.GrpcClient`/`Grpc.call` for portable unary calls and
   `Typed.generatedClientLayer` for generated clients. Use the canonical scoped
   persistent-channel or bounded-pool layers for long-lived native clients.
5. Declare connection, stream, header, message, queue, deadline, retry,
   keepalive and shutdown limits. Transparent retry is legal only before HTTP/2
   response commitment. Use incremental streaming when production flow control
   and backpressure matter.
6. The canonical channel, pool, and server layers install their runtime-owned
   causal recorder automatically. Preserve bounded `x-request-id` and W3C
   `traceparent` propagation so transport and handler facts share correlation
   keys. Add semantic domain facts when useful; never record raw identifiers,
   metadata values, payloads, or credentials.
7. Use `VirtualWorld`, `FaultMatrix` and `Schedules` for retry, GOAWAY, RST,
   partition, certificate rotation, streaming and shutdown behavior. Run the
   applicable official gRPC and Connect conformance lanes and preserve explicit
   unsupported cases.
8. For Cloud Run, compose policy, implementation, generated routes, standard
   health/reflection, Channelz, middleware, and the server as one root layer.
   Build one `zstd.ManagedRuntime`, bind `0.0.0.0:$PORT` using h2c behind
   platform TLS, use audience-bound service identity, and drain on SIGTERM.
9. Run `bun run zigeffect:architecture:test` and
   `bun run zigeffect:grpc:test`. The latter includes native Testing v2, the
   Cloud Run build, schema compatibility, and browser Connect tests.
10. Profile before tuning transport internals. Benchmark grpc-go, Tonic, gRPC
   C++, and ZigEffect only inside one complete receipt with identical payload,
   concurrency, connection, warm-up, container, and host settings. Preserve
   message, queue, retry, TLS, and malformed-peer defenses while optimizing.

The current working baseline is the schema-v2 ARM64 Docker optimization
diagnostic: 11,792 RPC/s for 1 KiB unary, 96.6% of grpc-go in the same receipt,
and 13.4% higher throughput than Tonic, with 2.42 ms p50, 6.06 ms p99, and 7.0
server allocations per RPC. It is candidate engineering evidence, not a release
or Cloud Run performance promise. Read
`packages/zigeffect-grpc/benchmarks/PERFORMANCE.md` before repeating or changing
the claim.

`zigeffect-grpc` remains `production_candidate` until a schema-v2 receipt from
committed source includes native Linux amd64, the complete 24-hour mixed-shape
bounded-memory campaign, and deployed GCP service-to-service qualification. A
workflow definition, local-only container result, unsupported case, stale
receipt, or uncommitted source must never be promoted into release evidence.
Read `packages/zigeffect/docs/grpc-cloud-run.md` and
`packages/zigeffect-grpc/README.md` for the current architecture and gates.

## Specify behavior with `zstd.Testing`

ZigEffect has two complementary Testing v2 layers:

- ordinary Zig unit tests keep using `std.testing`, but every first-party and
  generated `b.addTest` artifact must use the server runner exported as
  `zigeffect_test_runner` by `zigeffect`/`zigeffect_std`;
- semantic acceptance tests use `zstd.Testing.TestContext`,
  `AssertionRecorder`, and the advanced deterministic facilities below.

Do not mechanically replace precise `std.testing` assertions with receipt
boilerplate. A legacy test is migrated when its build artifact uses the V2
runner. After any package-native `zig build test`, read
`.zigeffect/tests/suites/<artifact-name>.json` first and require `complete`, a
`passed` status, equal discovered/executed counts, zero pending tests, zero
leaks, and zero logged errors. The suite receipt records Zig version, target,
optimization mode, seed, stable test identities, durations, errors, and the
replay command. Missing or malformed suite evidence is not a pass.

For a new build file, obtain the runner from the existing dependency rather
than adding a new runtime dependency:

```zig
const zstd_dependency = b.dependency("zigeffect_std", .{});
const zstd = zstd_dependency.module("zigeffect_std");
const runner = zstd_dependency.module("zigeffect_test_runner").root_source_file.?;
const tests = b.addTest(.{
    .name = "app-tests",
    .root_module = test_module,
    .test_runner = .{ .path = runner, .mode = .server },
});
```

Add a failing deterministic test before a behavior change. Register the
scenario in `test_scenarios`, linked to its requirement, acceptance check,
component, command, source roots, stable seed, and required status.

Use `zstd.Testing.TestContext` to run effects against deterministic services and
the real bounded causal store. Record assertions with stable IDs, meaningful
labels, source references when useful, and actionable repair hints:

```zig
const std = @import("std");
const zstd = @import("zigeffect_std");

test "accepted order is causally complete" {
    const scenario = zstd.Testing.Scenario{
        .id = "accept-order",
        .label = "accepted order is durable",
        .requirement = "req-order",
        .acceptance_check = "check-order",
        .component = "orders",
        .command = "test",
    };
    var context = try zstd.Testing.TestContext.initFromProject(
        std.testing.allocator,
        std.testing.io,
        std.Io.Dir.cwd(),
        .{
            .project = "app",
            .suite = "acceptance",
            .scenario = scenario,
            .seed = 42,
        },
    );
    defer context.deinit();

    const assertions = zstd.Testing.AssertionRecorder.init(&context);
    try assertions.boolean(.{
        .id = "order-durable",
        .label = "the order is durable",
        .repair_hint = "make the write and idempotency key atomic",
    }, true);
    try assertions.noPendingFibers(.{ .id = "fibers-clean", .label = "no work escaped its scope" });
    try assertions.noFindings(.{ .id = "causal-clean", .label = "runtime invariants remain clean" });

    try context.publish(std.testing.io, std.Io.Dir.cwd(), 1);
}
```

Use the smallest technique that proves the boundary:

- `AssertionRecorder` for values, semantic JSON, `Exit`, `Cause`, event
  sequences, findings, pending fibers, and secret scans;
- `FaultMatrix` for bounded allocation, scheduling, timeout, cancellation,
  retry, process, HTTP, SQL, journal, and artifact failures;
- `Generators.runProperty` for deterministic Schema-derived properties and
  structural/custom shrinking with an explicit shrink path;
- `Coverage` for requirement, acceptance, fault, causal, statechart, schema,
  mutation, executor, performance, and sandbox targets and gaps;
- `Models.StatechartExplorer` and `Schedules` for bounded typed model and
  interleaving exploration with shortest replayable failures;
- `Differential` for normalized cross-executor comparison;
- `VirtualWorld` for deterministic delay, drop, duplication, reordering,
  partition, redelivery, stale/conflicting/partial storage, crash, and recovery;
- `Mutation` for stable requirement-linked mutants without source-tree writes;
- `Budgets` for deterministic absolute/relative performance contracts;
- `Sandbox.Firewall` for fake-by-default, explicit-real side-effect authority;
- semantic snapshots for durable artifacts whose meaning matters more than
  formatting.

Unsupported cases, exhausted bounds, dropped evidence, and truncation must stay
visible in the receipt. Never translate them into a pass.

Initialize through `initFromProject` and end with `publish`. The CLI writes the
control document before starting the manifest command and only accepts a
matching native process receipt. Exit zero without that receipt is incomplete.
Package-native runs publish raw receipts separately and cannot replace stable
controlled proof. Attach advanced reports with
`context.recordReport(.<kind>, report)`.

## Iterate from evidence

1. Before editing, run `zigeffect agent context --task <id> --budget 65536
   --json`. Treat its content-addressed source identity, derived requirement
   state, exact proof references, authority, omissions, and follow-up queries as
   the compact orientation artifact. Retain its graph
   `newest_durable_event_id` as the baseline. When the running application
   exposes its guarded application-map endpoint, query it first: one response
   identifies service topology, layer/runtime state, recent semantic events,
   embedded NenDB health, the graph cursor, and bounded follow-up queries.
2. Use that graph plus the requirement, contract, and scope to state a
   counterfactual: which service calls, external boundaries, domain facts, and
   causal descendants should appear after the change, and which slices must
   remain unchanged. Never infer the whole application from filenames when the
   runtime map is available.
3. Run `zigeffect test affected --changed <path> --json` for each relevant
   changed path, then execute the selected scenario or requirement.
4. Read `.zigeffect/tests/latest.json`, then the stable native receipt at
   `.zigeffect/tests/process-receipts/<scenario>.json` and proof handoff at
   `.zigeffect/handoffs/tests/<scenario>.json`. Validate their schema/version,
   source and manifest identities, command digest, native tool/target/optimize
   identity, and require discovered, selected, and status counts to agree.
5. Query `zigeffect graph since <baseline-event-id> --limit 256 --json`. Compare
   the ordered causal delta with the counterfactual and acceptance contract.
   Continue in bounded pages from `next_event_id` when `truncated` is true.
   Empty, dropped, unhealthy, unexpectedly broad, or truncated-and-unread
   evidence is not a pass.
6. On failure, inspect the first failed assertion, source reference, repair hint,
   causal event IDs, and `causal_event_id_space`. When the space is
   `graph_durable`, query `zigeffect graph event <id> --json` and `zigeffect
   graph children <id> --json` before reconstructing the failure from text.
   When two events bound the suspected behavior, query `zigeffect graph path
   <from> <to> --limit 128 --json` and use the returned path as the proof.
   A `runtime_local` ID is not a durable graph cursor and must not be queried as
   one.
7. Copy the receipt's exact `zigeffect test replay` command. Preserve its seed,
   fault kind, fault index, root, and bounds while repairing the smallest
   responsible boundary.
8. Use `zigeffect safety explain <finding-id>` for source-linked safety repairs.
   Do not add unmanaged roots or unaudited escape hatches.
9. Compare with `zigeffect test snapshot <scenario> --json`. Apply only an
   inspected intentional change with `--apply --json`; never bless an unexplained
   diff.
10. Run `zigeffect test coverage --json` and `zigeffect test gaps --json`; close
   every required gap. Use `zigeffect test stress --runs <n> --json` for bounded
   multi-seed evidence and `zigeffect test history --json` for introduced and
   resolved failure fingerprints.

## Verify and hand off

Run application gates in this order:

```sh
zigeffect project validate --json
zigeffect test run --requirement <requirement-id> --json
zigeffect test coverage --requirement <requirement-id> --json
zigeffect test gaps --requirement <requirement-id> --json
zigeffect project test --json
zigeffect project check --agent --json
```

Then confirm `.zigeffect/tests/latest.json` is complete, stable process receipts
and proof handoffs match the current source/manifest, required scenarios pass,
and receipts are bounded and redacted. Run `zigeffect agent handoff --provider
<harness> --session <id> --json`, attaching changed requirements, acceptance
status, receipt paths, replay commands, and relevant causal IDs.

State every failed or unrun gate plainly. Never mark a requirement satisfied
without passing evidence, and never claim ZigEffect proves memory safety or
schedule/input completeness beyond the compiler mode, platform, cases, and
bounds recorded in the receipt.

For multi-agent work, integrate proof rather than prose. Each implementer owns
one non-overlapping work packet and returns a proof bundle bound to its source
baseline, lease fencing token, changed paths, verification digests, receipts,
and causal IDs. An independent reviewer or qualifier must not repair the
candidate it evaluates. Repair memory may suggest a strategy, but it is never
current evidence or authority.
