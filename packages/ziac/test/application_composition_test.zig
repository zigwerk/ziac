const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const scenario = zstd.Testing.Scenario{
    .id = "effect-native-plan-execute",
    .label = "plan and execute through the canonical Ziac runtime",
    .requirement = "zigeffect-composable-control-plane",
    .acceptance_check = "check-zigeffect-composable-control-plane",
    .component = "ziac",
    .command = "test",
};

const FakeCompiler = struct {
    pub fn build(
        self: *FakeCompiler,
        allocator: std.mem.Allocator,
        args: ziac.stack_registry.StackArgs,
    ) !ziac.stack_registry.StackProgram {
        _ = self;
        return ziac.stack_registry.fixtureRegistry().build(allocator, args);
    }
};

test "Ziac planning and execution compose as services in one durable runtime" {
    var evidence = try zstd.Testing.TestContext.initFromProject(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), .{
        .project = "ziac",
        .suite = "ziac-tests",
        .scenario = scenario,
        .seed = 115,
    });
    defer evidence.deinit();
    const assertions = zstd.Testing.AssertionRecorder.init(&evidence);

    var desired = ziac.ResourceGraph.init(std.testing.allocator);
    defer desired.deinit();
    try desired.addResource(.{
        .id = "gcp.test.Resource.service",
        .provider = .gcp,
        .type_name = "gcp.test.Resource",
        .logical_id = "service",
        .inputs = .{ .object = &.{
            .{ .name = "name", .value = .{ .string = "service" } },
        } },
    });
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, fake.provider());
    var compiler = FakeCompiler{};

    const main_layer = ziac.application.rootLayer(
        ziac.application.ProjectCompilerApi.from(FakeCompiler, &compiler),
        &state,
        providers,
        .{},
        .{},
    );
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

    var planned = try runtime.run(ziac.application.planEffect(&desired).named("ziac.command.plan"));
    defer planned.deinit();
    try runtime.run(ziac.application.executeEffect(&planned).named("ziac.command.execute"));

    var snapshot = try runtime.inspect(std.testing.allocator, .{ .max_recent_events = 256 });
    defer snapshot.deinit();
    try assertions.applicationService(.{
        .id = "ziac.composition.compiler-service",
        .label = "project compiler is visible in the application map",
        .repair_hint = "provide ProjectCompiler from the root layer",
    }, &snapshot, ziac.application.ProjectCompiler.service_key, true);
    try assertions.applicationOperation(.{
        .id = "ziac.composition.compiler-operation",
        .label = "project compilation is discoverable in the application map",
        .repair_hint = "declare ProjectCompiler.build in the service API",
    }, &snapshot, ziac.application.ProjectCompiler.service_key, "ProjectCompiler.build");
    try assertions.applicationService(.{
        .id = "ziac.composition.state-service",
        .label = "state store is visible in the application map",
        .repair_hint = "provide StateStore from the root layer",
    }, &snapshot, ziac.application.StateStore.service_key, true);
    try assertions.applicationService(.{
        .id = "ziac.composition.provider-service",
        .label = "provider registry is visible in the application map",
        .repair_hint = "provide ProviderRegistry from the root layer",
    }, &snapshot, ziac.application.ProviderRegistry.service_key, true);
    try assertions.applicationOperation(.{
        .id = "ziac.composition.provider-operation",
        .label = "provider execution is discoverable in the application map",
        .repair_hint = "declare ProviderRegistry.execute in the service API",
    }, &snapshot, ziac.application.ProviderRegistry.service_key, "ProviderRegistry.execute");
    try assertions.applicationService(.{
        .id = "ziac.composition.spawner-service",
        .label = "process spawner is visible in the application map",
        .repair_hint = "provide ProcessSpawner from the root layer",
    }, &snapshot, ziac.application.ProcessSpawner.service_key, true);
    try assertions.applicationOperation(.{
        .id = "ziac.composition.spawner-operation",
        .label = "verification process execution is discoverable in the application map",
        .repair_hint = "declare ProcessSpawner.verify in the service API",
    }, &snapshot, ziac.application.ProcessSpawner.service_key, "ProcessSpawner.verify");
    try assertions.boolean(.{
        .id = "ziac.composition.state-created",
        .label = "composed execution creates state",
        .source = .{ .id = "ziac-composition-test", .path = "packages/ziac/test/application_composition_test.zig", .line = 84, .column = 1 },
        .repair_hint = "ensure ExecuteEffect resolves StateStore and ProviderRegistry",
    }, state.get("gcp.test.Resource.service") != null);
    _ = try assertions.event(.{
        .id = "ziac.composition.plan-causal",
        .label = "planning records semantic causal evidence",
        .source = .{ .id = "ziac-composition-test", .path = "packages/ziac/test/application_composition_test.zig", .line = 91, .column = 1 },
        .repair_hint = "record the pure plan boundary through the runtime recorder",
    }, .{ .kind = .activity_completed, .label = "ziac.plan.build", .status = "success" });
    _ = try assertions.event(.{
        .id = "ziac.composition.execute-causal",
        .label = "execution records semantic causal evidence",
        .source = .{ .id = "ziac-composition-test", .path = "packages/ziac/test/application_composition_test.zig", .line = 98, .column = 1 },
        .repair_hint = "record the provider execution boundary through the runtime recorder",
    }, .{ .kind = .activity_completed, .label = "ziac.plan.execute", .status = "success" });
    try assertions.noPendingFibers(.{
        .id = "ziac.composition.no-pending-fibers",
        .label = "composed control plane joins all fibers",
        .repair_hint = "join executor children before the command scope exits",
    });
    try assertions.noFindings(.{
        .id = "ziac.composition.no-findings",
        .label = "composed control plane has no causal safety findings",
        .repair_hint = "close every command scope and complete semantic operations",
    });

    try evidence.mapCausalEventIds(&runtime);
    try std.testing.expectEqual(zstd.Testing.CausalEventIdSpace.graph_durable, evidence.causal_event_id_space);
    var saw_queryable_assertion = false;
    for (evidence.assertions.items) |assertion| {
        for (assertion.causal_event_ids) |event_id| {
            const record = try runtime.graphRecordJsonAlloc(std.testing.allocator, event_id);
            defer std.testing.allocator.free(record);
            if (std.mem.indexOf(u8, record, "ziac.plan") != null) saw_queryable_assertion = true;
        }
    }
    try std.testing.expect(saw_queryable_assertion);
    try runtime.shutdown();
    try evidence.publish(std.testing.io, std.Io.Dir.cwd(), 1);
}
