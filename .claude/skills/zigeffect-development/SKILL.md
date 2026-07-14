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

## Establish the application contract

Before editing application behavior:

1. Run `zigeffect compatibility --json` and read `zigeffect.project.json`.
   Inspect migrations with `zigeffect upgrade --dry-run --json`; never rewrite
   around a reported conflict.
2. Run `zigeffect project validate --json`, `zigeffect agent status --json`,
   `zigeffect agent next --json`, and `zigeffect test list --json`.
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
3. Implement typed handlers through generated service bindings, effects,
   layers, scoped resources and typed errors. Use a scoped persistent channel or
   bounded channel pool for long-lived service clients.
4. Declare connection, stream, header, message, queue, deadline, retry,
   keepalive and shutdown limits. Transparent retry is legal only before HTTP/2
   response commitment. Use incremental streaming when production flow control
   and backpressure matter.
5. Emit redacted causal facts for resolve, connect, pick, attempt, stream,
   handler and drain. Export trace context, OTLP histograms, attempt/connection
   instruments, propagation links and exemplars without payloads or credentials.
6. Use `VirtualWorld`, `FaultMatrix` and `Schedules` for retry, GOAWAY, RST,
   partition, certificate rotation, streaming and shutdown behavior. Run the
   applicable official gRPC and Connect conformance lanes and preserve explicit
   unsupported cases.
7. For Cloud Run, bind `0.0.0.0:$PORT` using h2c behind platform TLS, install
   health/reflection/Channelz before readiness, use audience-bound service
   identity, and drain on SIGTERM.
8. Profile before tuning transport internals. Benchmark grpc-go, Tonic, gRPC
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
Attach advanced reports with `context.recordReport(.<kind>, report)`.

## Iterate from evidence

1. Run `zigeffect test affected --changed <path> --json` for each relevant
   changed path, then execute the selected scenario or requirement.
2. Read `.zigeffect/tests/latest.json`. Validate its schema/version and require
   discovered, selected, and status counts to agree.
3. On failure, inspect the first failed assertion, source reference, repair hint,
   and causal event IDs. Query `zigeffect graph event <id> --json` and
   `zigeffect graph children <id> --json` before reconstructing the failure from
   text.
4. Copy the receipt's exact `zigeffect test replay` command. Preserve its seed,
   fault kind, fault index, root, and bounds while repairing the smallest
   responsible boundary.
5. Use `zigeffect safety explain <finding-id>` for source-linked safety repairs.
   Do not add unmanaged roots or unaudited escape hatches.
6. Compare with `zigeffect test snapshot <scenario> --json`. Apply only an
   inspected intentional change with `--apply --json`; never bless an unexplained
   diff.
7. Run `zigeffect test coverage --json` and `zigeffect test gaps --json`; close
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

Then confirm `.zigeffect/tests/latest.json` is complete, required scenarios pass,
and receipts are bounded and redacted. Run `zigeffect agent handoff --provider
<harness> --session <id> --json`, attaching changed requirements, acceptance
status, receipt paths, replay commands, and relevant causal IDs.

State every failed or unrun gate plainly. Never mark a requirement satisfied
without passing evidence, and never claim ZigEffect proves memory safety or
schedule/input completeness beyond the compiler mode, platform, cases, and
bounds recorded in the receipt.
