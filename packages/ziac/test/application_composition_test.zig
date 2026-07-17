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

    const application_layer = ziac.Application.layer(.{
        .stack = &desired,
        .state = &state,
        .providers = providers,
    });
    const main_layer = zstd.fx.kernel.Layer.mergeAll(.{
        application_layer,
        zstd.fx.kernel.Layer.succeed(
            ziac.application.ProjectCompiler,
            ziac.application.ProjectCompilerApi.from(FakeCompiler, &compiler),
        ),
        zstd.fx.kernel.Layer.succeed(ziac.application.ProcessSpawner, .{}),
    });
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

    try runtime.run(ziac.Application.program().named("ziac.application.acceptance"));

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
        .repair_hint = "derive plan semantics from Ziac.Application",
    }, .{ .kind = .span_recorded, .type_name = "ziac.plan", .status = "success" });
    _ = try assertions.event(.{
        .id = "ziac.composition.provider-causal",
        .label = "provider invocation records semantic causal evidence",
        .source = .{ .id = "ziac-composition-test", .path = "packages/ziac/test/application_composition_test.zig", .line = 98, .column = 1 },
        .repair_hint = "instrument provider methods in the reusable Provider adapter",
    }, .{ .kind = .span_recorded, .type_name = "ziac.provider.rpc", .status = "success" });
    _ = try assertions.event(.{
        .id = "ziac.composition.state-commit-causal",
        .label = "state commit records terminal semantic causal evidence",
        .repair_hint = "record state only after mutation and checkpoint success",
    }, .{ .kind = .span_recorded, .type_name = "ziac.state.commit", .status = "success" });
    try assertions.eventPath(.{
        .id = "ziac.composition.plan-to-state-path",
        .label = "plan, resource, provider and state semantics form one queryable path",
        .repair_hint = "preserve the per-resource parent chain through executor and provider adapters",
    }, .{ .kind = .span_recorded, .type_name = "ziac.plan", .status = "success" }, .{ .kind = .span_recorded, .type_name = "ziac.state.commit", .status = "success" }, 32);
    try assertions.counterfactual(.{
        .id = "ziac.composition.plan-resource-provider-path",
        .label = "a plan causes a resource operation that reaches its provider boundary",
        .repair_hint = "derive each resource recorder from the completed plan event",
    }, .{ .kind = .span_recorded, .type_name = "ziac.plan", .status = "success" }, .{ .kind = .span_recorded, .type_name = "ziac.resource.operation", .status = "started" }, .{ .kind = .span_recorded, .type_name = "ziac.provider.rpc", .status = "success" }, 32);
    try assertions.counterfactual(.{
        .id = "ziac.composition.resource-provider-state-path",
        .label = "a resource operation reaches state only through its provider boundary",
        .repair_hint = "parent state commits to the terminal provider event for the resource",
    }, .{ .kind = .span_recorded, .type_name = "ziac.resource.operation", .status = "started" }, .{ .kind = .span_recorded, .type_name = "ziac.provider.rpc", .status = "success" }, .{ .kind = .span_recorded, .type_name = "ziac.state.commit", .status = "success" }, 32);
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

test "Ziac Application run owns causal health and checked shutdown" {
    var desired = ziac.ResourceGraph.init(std.testing.allocator);
    defer desired.deinit();
    try desired.addResource(.{
        .id = "gcp.test.Resource.application-run",
        .provider = .gcp,
        .type_name = "gcp.test.Resource",
        .logical_id = "application-run",
        .inputs = .{ .object = &.{
            .{ .name = "name", .value = .{ .string = "application-run" } },
        } },
    });
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, fake.provider());
    const live = ziac.Application.layer(.{
        .stack = &desired,
        .state = &state,
        .providers = providers,
    });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try zstd.ManagedRuntime(@TypeOf(live)).make(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        live,
        .{},
    );

    try ziac.Application.run(&runtime);
    try std.testing.expect(state.get("gcp.test.Resource.application-run") != null);
}
