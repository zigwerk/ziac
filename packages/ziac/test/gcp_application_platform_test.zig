const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};
const image = "example.invalid/platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

test "ApplicationPlatform composes one deterministic least-privilege application slice" {
    var platform = try buildPlatform();
    defer platform.deinit();

    try platform.graph.validateAcyclic();
    try std.testing.expect(hasResourceType(&platform.graph, "gcp.run.Service"));
    try std.testing.expect(hasResourceType(&platform.graph, "gcp.storage.Bucket"));
    try std.testing.expect(hasResourceType(&platform.graph, "gcp.pubsub.Topic"));
    try std.testing.expect(hasResourceType(&platform.graph, "gcp.pubsub.Subscription"));
    try std.testing.expect(hasResourceType(&platform.graph, "gcp.tasks.Queue"));
    try std.testing.expect(hasResourceType(&platform.graph, "gcp.eventarc.Trigger"));
    try std.testing.expect(hasResourceType(&platform.graph, "gcp.run.Job"));
    try std.testing.expect(hasResourceType(&platform.graph, "gcp.scheduler.Job"));
    try std.testing.expect(hasResourceType(&platform.graph, "gcp.run.WorkerPool"));

    try expectOutputResource(platform.service, "gcp.run.Service.europe-west1.platform-api");
    try expectOutputResource(platform.bucket, "gcp.storage.Bucket.ziac-platform-uploads");
    try expectOutputResource(platform.topic, "gcp.pubsub.Topic.platform-events");
    try expectOutputResource(platform.subscription, "gcp.pubsub.Subscription.platform-events-push");
    try expectOutputResource(platform.queue, "gcp.tasks.Queue.europe-west1.platform-tasks");
    try expectOutputResource(platform.trigger, "gcp.eventarc.Trigger.europe-west1.platform-trigger");
    try expectOutputResource(platform.job, "gcp.run.Job.europe-west1.platform-job");
    try expectOutputResource(platform.schedule, "gcp.scheduler.Job.europe-west1.platform-job");
    try expectOutputResource(platform.worker_pool, "gcp.run.WorkerPool.europe-west1.platform-worker");

    const service_id = platform.service.resource_ref.resource_id;
    try std.testing.expect(hasDependency(&platform.graph, service_id, "gcp.iam.ServiceAccount.platform-runtime"));
    try std.testing.expect(hasDependency(&platform.graph, "gcp.run.ServiceIamMember.platform-tasks-invoker", service_id));
    try std.testing.expect(hasDependency(&platform.graph, "gcp.run.ServiceIamMember.platform-events-push-invoker", service_id));
    try std.testing.expect(hasDependency(&platform.graph, "gcp.run.ServiceIamMember.platform-trigger-invoker", service_id));

    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &platform.graph);
    defer requirements.deinit(std.testing.allocator);
    for ([_][]const u8{
        "run.googleapis.com",
        "storage.googleapis.com",
        "pubsub.googleapis.com",
        "cloudtasks.googleapis.com",
        "eventarc.googleapis.com",
        "cloudscheduler.googleapis.com",
        "iam.googleapis.com",
    }) |api| try std.testing.expect(contains(requirements.apis, api));

    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(std.testing.allocator, &platform.graph);
    defer permissions.deinit(std.testing.allocator);
    try std.testing.expect(permissions.hasPermission(.runtime, "storage.objects.create"));
    try std.testing.expect(permissions.hasPermission(.runtime, "pubsub.topics.publish"));
    try std.testing.expect(permissions.hasPermission(.runtime, "cloudtasks.tasks.create"));
    try std.testing.expect(permissions.hasPermission(.runtime, "run.routes.invoke"));

    var role = try ziac.gcp.intelligence.proposeCustomRole(std.testing.allocator, permissions, .deployer, "ziacApplicationDeployer");
    defer role.deinit(std.testing.allocator);
    try std.testing.expect(role.permissions.len > 0);
}

test "ApplicationPlatform graph and visual projection are byte deterministic" {
    var first = try buildPlatform();
    defer first.deinit();
    var second = try buildPlatform();
    defer second.deinit();

    const first_digest = try ziac.plan.desiredGraphDigestAlloc(std.testing.allocator, &first.graph);
    const second_digest = try ziac.plan.desiredGraphDigestAlloc(std.testing.allocator, &second.graph);
    try std.testing.expectEqualSlices(u8, &first_digest, &second_digest);

    var first_artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &first.graph, null, .{
        .stack = "application-platform",
        .stage = "test",
        .created_at_millis = 1,
    });
    defer first_artifact.deinit();
    var second_artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &second.graph, null, .{
        .stack = "application-platform",
        .stage = "test",
        .created_at_millis = 1,
    });
    defer second_artifact.deinit();

    try std.testing.expectEqualStrings(first_artifact.bytes, second_artifact.bytes);
    try std.testing.expect(std.mem.indexOf(u8, first_artifact.bytes, "\"async_delivery\":{\"kind\":\"queue\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_artifact.bytes, "\"run_workload\":{\"kind\":\"worker_pool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_artifact.bytes, "\"kind\":\"iam\",\"access\":\"write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_artifact.bytes, "\"origin\":\"configuration_estimate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_artifact.bytes, "\"is_billing_export\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_artifact.bytes, "secret_ref") == null);
}

test "ApplicationPlatform applies imports refreshes no-op and preserves retained resources" {
    var platform = try buildPlatform();
    defer platform.deinit();

    var remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer remote.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.gcp, remote.provider());

    var primary_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer primary_state.deinit();
    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &platform.graph, &primary_state);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &primary_state, providers, .{});
    try std.testing.expectEqual(platform.graph.resources.items.len, remote.creates);

    var imported_remote = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer imported_remote.deinit();
    var imported_providers = ziac.provider.ProviderRegistry{};
    imported_providers.register(.gcp, imported_remote.provider());
    var imported_state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer imported_state.deinit();
    for (platform.graph.resources.items) |node| {
        const record = primary_state.get(node.id) orelse return error.MissingRecord;
        try ziac.importer.importResource(
            std.testing.allocator,
            node,
            record.physical_id orelse return error.MissingRecord,
            &imported_state,
            imported_providers,
            null,
        );
    }

    var imported_plan = try ziac.plan.buildPlan(std.testing.allocator, &platform.graph, &imported_state);
    defer imported_plan.deinit();
    for (imported_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);

    try std.testing.expectEqual(platform.graph.resources.items.len, imported_remote.imports);
    var refreshed_plan = try ziac.plan.buildRefreshedPlan(std.testing.allocator, &platform.graph, &imported_state, imported_providers);
    defer refreshed_plan.deinit();
    for (refreshed_plan.operations) |operation| try std.testing.expectEqual(ziac.plan.OperationKind.noop, operation.kind);

    var retained_count: usize = 0;
    for (platform.graph.resources.items) |node| retained_count += @intFromBool(node.lifecycle.retain_on_delete);
    var destroy_plan = try ziac.plan.buildDestroyPlan(std.testing.allocator, &primary_state);
    defer destroy_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &destroy_plan, &primary_state, providers, .{
        .destructive_confirmation = true,
    });
    try std.testing.expectEqual(platform.graph.resources.items.len - retained_count, remote.deletes);

    for (platform.graph.resources.items) |node| {
        var observed = try remote.provider().read(std.testing.allocator, node);
        defer observed.deinit();
        try std.testing.expectEqual(node.lifecycle.retain_on_delete, observed == .present);
    }

    var receipt = try ziac.gcp.application_platform_qualification.serializeLocalAlloc(std.testing.allocator, &platform.graph, .{
        .created = remote.creates,
        .imported = platform.graph.resources.items.len,
        .no_op = imported_plan.operations.len,
        .retained = retained_count,
        .deleted = remote.deletes,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.application-platform-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"status\":\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"authenticated\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"cost_origin\":\"configuration_estimate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "sentinel-secret-for-tests") == null);
}

fn buildPlatform() !ziac.gcp.ApplicationPlatform {
    return ziac.gcp.ApplicationPlatform.build(std.testing.allocator, provider, .{
        .name = "platform",
        .project_number = "123456789012",
        .image = image,
        .service_origin = "https://platform-api.example.run.app",
        .bucket_name = "ziac-platform-uploads",
        .location = "EU",
        .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" },
        .cors_origins = &.{"https://app.example.com"},
        .schedule = "0 2 * * *",
        .retain_data = true,
    });
}

fn hasResourceType(graph: *const ziac.resource.ResourceGraph, type_name: []const u8) bool {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return true;
    return false;
}

fn hasDependency(graph: *const ziac.resource.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| {
        if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    }
    return false;
}

fn expectOutputResource(value: anytype, expected: []const u8) !void {
    try std.testing.expect(value == .resource_ref);
    try std.testing.expectEqualStrings(expected, value.resource_ref.resource_id);
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}
