const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const scenario = zstd.Testing.Scenario{
    .id = "ziac-agent-development-context",
    .label = "Ziac exposes one proof-carrying development context endpoint",
    .requirement = "ziac-proof-carrying-development-context",
    .acceptance_check = "check-ziac-proof-carrying-development-context",
    .component = "ziac",
    .command = "test",
};

fn contextManifest() zstd.Project.Manifest {
    return .{
        .name = "context-app",
        .kind = .application,
        .components = &.{.{ .id = "context-app", .kind = .application, .path = "." }},
        .commands = &.{.{ .id = "test", .argv = &.{ "zig", "build", "test" } }},
        .requirements = &.{.{ .id = "inspect-context", .summary = "inspect bounded development context", .component = "context-app", .status = .active }},
        .acceptance_checks = &.{.{ .id = "check-context", .requirement = "inspect-context", .command = "test", .expectation = "context is compiled", .status = .pending }},
        .test_scenarios = &.{.{
            .id = "context-scenario",
            .label = "context scenario",
            .requirement = "inspect-context",
            .acceptance_check = "check-context",
            .component = "context-app",
            .command = "test",
            .source_roots = &.{"src"},
        }},
    };
}

test "Ziac native development context endpoint compiles bounded reconciled project truth" {
    var evidence = try zstd.Testing.TestContext.initFromProject(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), .{
        .project = "ziac",
        .suite = "ziac-tests",
        .scenario = scenario,
        .seed = 317,
    });
    defer evidence.deinit();
    const assertions = zstd.Testing.AssertionRecorder.init(&evidence);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = contextManifest();
    const manifest_json = try project.jsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(manifest_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zigeffect.project.json", .data = manifest_json });

    var native = ziac.agent_tools.NativeContextProvider{
        .io = std.testing.io,
        .project_dir = tmp.dir,
    };
    const provider = native.provider();
    const main_layer = ziac.agent_tools.contextLayer(provider);
    var runtime = try zstd.ManagedRuntime(@TypeOf(main_layer)).make(
        std.testing.allocator,
        std.testing.io,
        std.Io.Dir.cwd(),
        main_layer,
        .{
            .causal_store = evidence.causalStore(),
            .graph = .{ .path = ".zigeffect/graph" },
        },
    );
    defer runtime.deinit();
    const json = try runtime.run(ziac.agent_tools.compileContext(
        "{\"task\":\"task-inspect-context\",\"budget\":4096,\"changed_paths\":[\"src/main.zig\"]}",
    ).named("ziac.context.compile"));
    defer std.testing.allocator.free(json);

    try assertions.boolean(.{
        .id = "ziac.context.schema",
        .label = "the endpoint returns the canonical ZigEffect development context",
        .repair_hint = "delegate Ziac context compilation to zstd.Development",
    }, std.mem.indexOf(u8, json, zstd.Development.context_schema) != null);
    try assertions.boolean(.{
        .id = "ziac.context.task",
        .label = "the endpoint selects the requested requirement and affected scenario",
        .repair_hint = "preserve task and changed-path selection through the native provider",
    }, std.mem.indexOf(u8, json, "inspect-context") != null and std.mem.indexOf(u8, json, "context-scenario") != null);
    try assertions.boolean(.{
        .id = "ziac.context.budget",
        .label = "the context compiler enforces its requested token proxy budget",
        .repair_hint = "use the standard-library bounded context compiler",
    }, json.len <= 4096);
    _ = try assertions.event(.{
        .id = "ziac.context.causal",
        .label = "context compilation is recorded by the owning managed runtime",
        .repair_hint = "interpret ContextService through the process managed runtime",
    }, .{
        .kind = .activity_completed,
        .label = "DevelopmentContext.compile",
        .status = "success",
    });
    try assertions.noPendingFibers(.{
        .id = "ziac.context.no-pending-fibers",
        .label = "context compilation leaves no pending work",
        .repair_hint = "join evidence and graph queries before returning the context",
    });
    try assertions.noFindings(.{
        .id = "ziac.context.no-findings",
        .label = "context compilation records no causal safety findings",
        .repair_hint = "keep context reads bounded, redacted, and mutation-free",
    });
    try evidence.mapCausalEventIds(&runtime);
    try std.testing.expectEqual(zstd.Testing.CausalEventIdSpace.graph_durable, evidence.causal_event_id_space);
    var project_graph = try zstd.CausalGraph.Snapshot.open(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), .{
        .path = ".zigeffect/graph",
    });
    defer project_graph.deinit();
    var mapped_context_event_is_queryable = false;
    for (evidence.assertions.items) |assertion| {
        if (!std.mem.eql(u8, assertion.id, "ziac.context.causal")) continue;
        for (assertion.causal_event_ids) |event_id| {
            const record = try project_graph.recordJsonAlloc(std.testing.allocator, event_id);
            defer std.testing.allocator.free(record);
            if (std.mem.indexOf(u8, record, "DevelopmentContext.compile") != null) {
                mapped_context_event_is_queryable = true;
            }
        }
    }
    try std.testing.expect(mapped_context_event_is_queryable);
    try runtime.shutdown();
    try evidence.publish(std.testing.io, std.Io.Dir.cwd(), 1);
}
