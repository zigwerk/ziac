const std = @import("std");
const ziac = @import("ziac");

fn addNode(graph: *ziac.ResourceGraph, id: []const u8) !void {
    try graph.addResource(.{
        .id = id,
        .provider = .gcp,
        .type_name = "gcp.test.Resource",
        .logical_id = id,
        .inputs = .{ .object = &.{
            .{ .name = "name", .value = .{ .string = id } },
        } },
    });
}

fn registryFor(fake: *ziac.provider.FakeProvider) ziac.provider.ProviderRegistry {
    var registry = ziac.provider.ProviderRegistry{};
    registry.register(.gcp, fake.provider());
    return registry;
}

fn cancelAfterAttempts(
    token: *ziac.executor.CancellationToken,
    fake: *ziac.provider.FakeProvider,
    expected_attempts: usize,
) void {
    while (fake.operationAttempts() < expected_attempts) std.atomic.spinLoopHint();
    token.cancel();
}

test "planner retains resource dependencies for execution and state" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    try addNode(&graph, "repository");
    try graph.addDependency("service", "repository");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();

    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.operations[0].dependencies.len);
    try std.testing.expectEqualStrings("repository", plan.operations[0].dependencies[0]);
    try std.testing.expectEqual(@as(usize, 0), plan.operations[1].dependencies.len);

    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    try ziac.executor.executePlan(
        std.testing.allocator,
        &plan,
        &state,
        registryFor(&fake),
        .{},
    );
    const service = state.get("service").?;
    try std.testing.expectEqual(@as(usize, 1), service.dependencies.len);
    try std.testing.expectEqualStrings("repository", service.dependencies[0]);
}

test "execution schedule is stable and dependencies precede consumers" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    try addNode(&graph, "repository");
    try addNode(&graph, "database");
    try graph.addDependency("service", "repository");
    try graph.addDependency("service", "database");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();

    var schedule = try ziac.executor.buildSchedule(std.testing.allocator, &plan);
    defer schedule.deinit();

    try std.testing.expectEqual(@as(usize, 2), schedule.levels.len);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1 }, schedule.levels[0].operation_indexes);
    try std.testing.expectEqualSlices(usize, &.{0}, schedule.levels[1].operation_indexes);
}

test "destroy schedule runs consumers before their dependencies" {
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "repository",
        .provider = .gcp,
        .type_name = "gcp.test.Resource",
        .logical_id = "repository",
        .desired_hash = "repo-hash",
        .status = .created,
    });
    try state.put(.{
        .resource_id = "service",
        .provider = .gcp,
        .type_name = "gcp.test.Resource",
        .logical_id = "service",
        .desired_hash = "service-hash",
        .dependencies = &.{"repository"},
        .status = .created,
    });
    var plan = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer plan.deinit();

    var schedule = try ziac.executor.buildSchedule(std.testing.allocator, &plan);
    defer schedule.deinit();

    try std.testing.expectEqual(@as(usize, 2), schedule.levels.len);
    try std.testing.expectEqualStrings(
        "service",
        plan.operations[schedule.levels[0].operation_indexes[0]].resource.id,
    );
    try std.testing.expectEqualStrings(
        "repository",
        plan.operations[schedule.levels[1].operation_indexes[0]].resource.id,
    );
}

test "executor propagates destructive confirmation only when requested" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &state, registryFor(&fake), .{});

    var destroy_plan = try ziac.plan.buildDestroyPlan(std.testing.allocator, &state);
    defer destroy_plan.deinit();
    try std.testing.expectError(
        error.DestructiveConfirmationRequired,
        ziac.executor.executePlan(std.testing.allocator, &destroy_plan, &state, registryFor(&fake), .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.deletes);
    try ziac.executor.executePlan(std.testing.allocator, &destroy_plan, &state, registryFor(&fake), .{
        .destructive_confirmation = true,
    });

    try std.testing.expect(fake.last_delete_destructive_confirmation);
}

test "executor rejects an unconfirmed replacement before provider access" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    plan.operations[0].kind = .replace;
    plan.preconditions.operations_digest = try ziac.plan.operationsDigestAlloc(std.testing.allocator, plan.operations);
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(
        error.DestructiveConfirmationRequired,
        ziac.executor.executePlan(std.testing.allocator, &plan, &state, registryFor(&fake), .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.operationAttempts());
}

test "dependency failure prevents consumer execution" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    try addNode(&graph, "repository");
    try graph.addDependency("service", "repository");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.fail_next = error.AuthenticationFailed;
    const registry = registryFor(&fake);

    try std.testing.expectError(
        error.AuthenticationFailed,
        ziac.executor.executePlan(std.testing.allocator, &plan, &state, registry, .{}),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.operationAttempts());
    try std.testing.expect(state.get("service") == null);
    try std.testing.expectEqual(ziac.ResourceStatus.failed, state.get("repository").?.status);
}

test "independent operations overlap without exceeding the configured bound" {
    const allocator = std.heap.smp_allocator;
    var graph = ziac.ResourceGraph.init(allocator);
    defer graph.deinit();
    try addNode(&graph, "alpha");
    try addNode(&graph, "bravo");
    try addNode(&graph, "charlie");
    try addNode(&graph, "delta");
    var state = ziac.InMemoryStateStore.init(allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(allocator, &graph, &state);
    defer plan.deinit();
    var fake = ziac.provider.FakeProvider.init(allocator);
    defer fake.deinit();
    fake.operation_delay_millis = 20;
    const registry = registryFor(&fake);
    var thread_pool = ziac.fx.ThreadPoolExecutor{ .allocator = allocator };

    try ziac.executor.executePlan(allocator, &plan, &state, registry, .{
        .max_concurrency = 2,
        .fiber_executor = thread_pool.executor(),
    });

    try std.testing.expectEqual(@as(usize, 2), fake.maxConcurrentOperations());
    try std.testing.expectEqual(@as(usize, 4), fake.creates);
}

test "retryable failures use the configured deterministic zigeffect schedule" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.fail_next = error.TransientFailure;
    const registry = registryFor(&fake);
    var clock = ziac.fx.Clock.fake(100);

    try ziac.executor.executePlan(std.testing.allocator, &plan, &state, registry, .{
        .clock = &clock,
        .retry_schedule = ziac.fx.Schedule.fixed(.{ .max_retries = 2, .delay_ms = 25 }),
    });

    try std.testing.expectEqual(@as(usize, 2), fake.operationAttempts());
    try std.testing.expectEqual(@as(u64, 125), clock.nowMs());
    try std.testing.expectEqual(ziac.ResourceStatus.created, state.get("service").?.status);
}

test "non-retryable failures stop immediately" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.fail_next = error.AuthorizationFailed;
    const registry = registryFor(&fake);
    var clock = ziac.fx.Clock.fake(100);

    try std.testing.expectError(
        error.AuthorizationFailed,
        ziac.executor.executePlan(std.testing.allocator, &plan, &state, registry, .{
            .clock = &clock,
            .retry_schedule = ziac.fx.Schedule.fixed(.{ .max_retries = 4, .delay_ms = 25 }),
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.operationAttempts());
    try std.testing.expectEqual(@as(u64, 100), clock.nowMs());
}

test "executor propagates bounded provider diagnostics from operation contexts" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, "service");
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.fail_next = error.QuotaExceeded;
    fake.diagnostic_next = .{
        .category = .quota,
        .service = "compute.googleapis.com",
        .status = 429,
        .quota_metric = "compute.googleapis.com/backend_services",
        .quota_limit = "BACKEND-SERVICES-per-project",
    };
    var diagnostics = ziac.provider_error.DiagnosticRecorder.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectError(
        error.QuotaExceeded,
        ziac.executor.executePlan(std.testing.allocator, &plan, &state, registryFor(&fake), .{
            .diagnostics = &diagnostics,
        }),
    );
    var recorded = (try diagnostics.snapshotAlloc(std.testing.allocator)).?;
    defer recorded.deinit();
    try std.testing.expectEqualStrings("compute.googleapis.com/backend_services", recorded.quota_metric.?);
    try std.testing.expectEqualStrings("BACKEND-SERVICES-per-project", recorded.quota_limit.?);
}

test "operation timeout prevents a retry beyond the resource deadline" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(.{
        .id = "service",
        .provider = .gcp,
        .type_name = "gcp.test.Resource",
        .logical_id = "service",
        .lifecycle = .{ .operation_timeout_millis = 10 },
    });
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.fail_next = error.TransientFailure;
    const registry = registryFor(&fake);
    var clock = ziac.fx.Clock.fake(100);

    try std.testing.expectError(
        error.ProviderTimeout,
        ziac.executor.executePlan(std.testing.allocator, &plan, &state, registry, .{
            .clock = &clock,
            .retry_schedule = ziac.fx.Schedule.fixed(.{ .max_retries = 2, .delay_ms = 25 }),
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.operationAttempts());
    try std.testing.expectEqual(@as(u64, 100), clock.nowMs());
}

test "cancellation interrupts in-flight provider children and records incomplete state" {
    const allocator = std.heap.smp_allocator;
    var graph = ziac.ResourceGraph.init(allocator);
    defer graph.deinit();
    try addNode(&graph, "alpha");
    try addNode(&graph, "bravo");
    var state = ziac.InMemoryStateStore.init(allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(allocator, &graph, &state);
    defer plan.deinit();
    var fake = ziac.provider.FakeProvider.init(allocator);
    defer fake.deinit();
    fake.operation_delay_millis = 50;
    const registry = registryFor(&fake);
    var cancellation = ziac.executor.CancellationToken{};
    var thread_pool = ziac.fx.ThreadPoolExecutor{ .allocator = allocator };
    const canceller = try std.Thread.spawn(.{}, cancelAfterAttempts, .{ &cancellation, &fake, 2 });
    defer canceller.join();

    try std.testing.expectError(
        error.ProviderCancelled,
        ziac.executor.executePlan(allocator, &plan, &state, registry, .{
            .cancellation = &cancellation,
            .fiber_executor = thread_pool.executor(),
            .max_concurrency = 2,
        }),
    );
    try std.testing.expectEqual(@as(usize, 2), fake.operationAttempts());
    try std.testing.expectEqual(ziac.ResourceStatus.failed, state.get("alpha").?.status);
    try std.testing.expectEqual(ziac.ResourceStatus.failed, state.get("bravo").?.status);
}

test "execution records redacted causal operation facts" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(.{
        .id = "service",
        .provider = .gcp,
        .type_name = "gcp.test.Resource",
        .logical_id = "service",
        .inputs = .{ .object = &.{
            .{ .name = "password", .value = .{ .string = "never-record-me" } },
        } },
    });
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    var plan = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state);
    defer plan.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    const registry = registryFor(&fake);
    var causal = ziac.fx.CausalStore.init(std.testing.allocator);
    defer causal.deinit();

    try ziac.executor.executePlan(std.testing.allocator, &plan, &state, registry, .{
        .causal_store = &causal,
    });
    var snapshot = try causal.snapshot(std.testing.allocator);
    defer snapshot.deinit();

    var operation_events: usize = 0;
    for (snapshot.events) |event| {
        if (event.kind != .workflow_event_recorded) continue;
        operation_events += 1;
        try std.testing.expect(std.mem.indexOf(u8, event.label, "never-record-me") == null);
    }
    try std.testing.expect(operation_events >= 2);
}
