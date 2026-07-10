const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const client_mod = ziac.cockroach.client;
const private_endpoint = ziac.cockroach.private_endpoint;

test "Cockroach regional projection resolves cluster output and preserves typed input" {
    const responses = [_]zstd.Http.Response{clusterResponse("STANDARD")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var region = try private_endpoint.ClusterRegion.build(std.testing.allocator, .{}, .{
        .name = "api-db",
        .cluster_id = ziac.PublicOutput([]const u8).fromResource("cockroach.Cluster.ziac-prod", "cluster_id"),
        .region = "europe-west1",
    });
    defer region.deinit(std.testing.allocator);
    var state = try clusterState();
    defer state.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = &state;

    var observed = try harness.live.provider().readWithContext(&context, region.node);
    defer observed.deinit();
    try std.testing.expect(observed == .present);
    try std.testing.expectEqual(region.node.inputs_hash, observed.present.observed_hash);
    try std.testing.expectEqualStrings("cluster-1:europe-west1", observed.present.physical_id);
    try std.testing.expectEqualStrings("private.eu.example", outputString(observed.present, "private_endpoint_dns"));
    try std.testing.expectEqualStrings("europe-west1", outputString(observed.present, "region"));
}

test "Standard private endpoint service polls without enabling serverless services" {
    const responses = [_]zstd.Http.Response{
        clusterResponse("STANDARD"),
        servicesResponse("CREATING"),
        servicesResponse("AVAILABLE"),
        clusterResponse("STANDARD"),
        servicesResponse("AVAILABLE"),
        clusterResponse("STANDARD"),
        servicesResponse("AVAILABLE"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var service = try endpointService(.standard);
    defer service.deinit(std.testing.allocator);
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;
    context.deadline_millis = 30_000;

    var created = try harness.live.provider().createWithContext(&context, service.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("cluster-1:europe-west1", created.physical_id);
    try std.testing.expectEqualStrings("AVAILABLE", outputString(created, "status"));
    context.physical_id = created.physical_id;
    var current = try harness.live.provider().readWithContext(&context, service.node);
    defer current.deinit();
    try std.testing.expectEqual(service.node.inputs_hash, current.present.observed_hash);
    var imported = try harness.live.provider().importWithContext(&context, service.node, created.physical_id);
    defer imported.deinit();
    try harness.live.provider().deleteWithContext(&context, service.node, created.physical_id);

    try std.testing.expectEqual(@as(u64, 1_000), clock.nowMs());
    for (harness.transport.requests.items) |request| {
        try std.testing.expect(!std.mem.eql(u8, request.method, "POST"));
    }
}

test "Advanced private endpoint service enables once then polls available" {
    const responses = [_]zstd.Http.Response{
        clusterResponse("ADVANCED"),
        emptyServicesResponse(),
        servicesResponse("CREATING"),
        servicesResponse("AVAILABLE"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var service = try endpointService(.advanced);
    defer service.deinit(std.testing.allocator);
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;

    var created = try harness.live.provider().createWithContext(&context, service.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[2].method);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.transport.requests.items[2].url,
        "/networking/private-endpoint-services",
    ));
    try std.testing.expectEqual(@as(u64, 1_000), clock.nowMs());
}

test "Advanced private endpoint service resumes an existing enable without another POST" {
    const responses = [_]zstd.Http.Response{
        clusterResponse("ADVANCED"),
        servicesResponse("CREATING"),
        servicesResponse("AVAILABLE"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var service = try endpointService(.advanced);
    defer service.deinit(std.testing.allocator);
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;

    var created = try harness.live.provider().createWithContext(&context, service.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("AVAILABLE", outputString(created, "status"));
    for (harness.transport.requests.items) |request| {
        try std.testing.expect(!std.mem.eql(u8, request.method, "POST"));
    }
    try std.testing.expectEqual(@as(u64, 1_000), clock.nowMs());
}

test "private endpoint connection polls acceptance imports and deletes" {
    const responses = [_]zstd.Http.Response{
        connectionsResponse(null, "STATUS_PENDING"),
        connectionsResponse(null, "STATUS_PENDING"),
        .{ .status = 200, .body = "{}" },
        connectionsResponse("service-1", "STATUS_PENDING_ACCEPTANCE"),
        connectionsResponse("service-1", "STATUS_REJECTED"),
        connectionsResponse("service-1", "STATUS_AVAILABLE"),
        connectionsResponse("service-1", "STATUS_AVAILABLE"),
        connectionsResponse("service-1", "STATUS_AVAILABLE"),
        .{ .status = 204, .body = "" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var connection = try endpointConnection();
    defer connection.deinit(std.testing.allocator);
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;
    context.deadline_millis = 30_000;

    var absent = try harness.live.provider().readWithContext(&context, connection.node);
    defer absent.deinit();
    try std.testing.expect(absent == .absent);
    var created = try harness.live.provider().createWithContext(&context, connection.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("cluster-1:123456789", created.physical_id);
    try std.testing.expectEqualStrings("STATUS_AVAILABLE", outputString(created, "status"));
    try std.testing.expectEqual(@as(u64, 2_000), clock.nowMs());
    context.physical_id = created.physical_id;
    var current = try harness.live.provider().readWithContext(&context, connection.node);
    defer current.deinit();
    try std.testing.expectEqual(connection.node.inputs_hash, current.present.observed_hash);
    var imported = try harness.live.provider().importWithContext(&context, connection.node, created.physical_id);
    defer imported.deinit();
    try harness.live.provider().deleteWithContext(&context, connection.node, created.physical_id);

    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[2].method);
    try std.testing.expectEqualStrings("{\"endpoint_id\":\"123456789\"}", harness.transport.requests.items[2].body);
    try std.testing.expectEqualStrings("DELETE", harness.transport.requests.items[8].method);
}

test "private endpoint connection read and create resume pending acceptance without duplicate POST" {
    const responses = [_]zstd.Http.Response{
        connectionsResponse("service-1", "STATUS_PENDING_ACCEPTANCE"),
        connectionsResponse("service-1", "STATUS_PENDING_ACCEPTANCE"),
        connectionsResponse("service-1", "STATUS_AVAILABLE"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var connection = try endpointConnection();
    defer connection.deinit(std.testing.allocator);
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;

    var pending = try harness.live.provider().readWithContext(&context, connection.node);
    defer pending.deinit();
    try std.testing.expect(pending == .absent);
    var resumed = try harness.live.provider().createWithContext(&context, connection.node);
    defer resumed.deinit();
    try std.testing.expectEqualStrings("STATUS_AVAILABLE", outputString(resumed, "status"));
    for (harness.transport.requests.items) |request| {
        try std.testing.expect(!std.mem.eql(u8, request.method, "POST"));
    }
    try std.testing.expectEqual(@as(u64, 1_000), clock.nowMs());
}

test "private endpoint provider rejects wrong service and obeys deadlines" {
    const wrong = [_]zstd.Http.Response{connectionsResponse("wrong-service", "STATUS_AVAILABLE")};
    var wrong_harness: Harness = undefined;
    wrong_harness.init(&wrong);
    defer wrong_harness.deinit();
    var connection = try endpointConnection();
    defer connection.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidConfiguration,
        wrong_harness.live.provider().readWithContext(&context, connection.node),
    );

    const pending = [_]zstd.Http.Response{
        connectionsResponse(null, "STATUS_PENDING"),
        .{ .status = 200, .body = "{}" },
        connectionsResponse("service-1", "STATUS_PENDING_ACCEPTANCE"),
    };
    var pending_harness: Harness = undefined;
    pending_harness.init(&pending);
    defer pending_harness.deinit();
    var clock = ziac.fx.Clock.fake(0);
    var deadline_context = ziac.provider.OperationContext.init(std.testing.allocator);
    deadline_context.clock = &clock;
    deadline_context.deadline_millis = 500;
    try std.testing.expectError(
        error.ProviderTimeout,
        pending_harness.live.provider().createWithContext(&deadline_context, connection.node),
    );
}

const Harness = struct {
    transport: @import("cockroach_client_test.zig").RecordingTransport,
    client: client_mod.Client,
    live: ziac.cockroach.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.transport = @import("cockroach_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = client_mod.Client.init(self.transport.client(), "dummy-key", .{});
        self.live = ziac.cockroach.live_provider.LiveProvider.init(&self.client);
        self.live.private_endpoint_poll_interval_millis = 1_000;
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.* = undefined;
    }
};

fn endpointService(plan: private_endpoint.EligiblePlan) !private_endpoint.PrivateEndpointService {
    return private_endpoint.PrivateEndpointService.build(std.testing.allocator, .{}, .{
        .name = "api-db",
        .cluster_id = ziac.PublicOutput([]const u8).known("cluster-1"),
        .plan = plan,
        .region = "europe-west1",
    });
}

fn endpointConnection() !private_endpoint.PrivateEndpointConnection {
    return private_endpoint.PrivateEndpointConnection.build(std.testing.allocator, .{}, .{
        .name = "api-db",
        .cluster_id = ziac.PublicOutput([]const u8).known("cluster-1"),
        .endpoint_id = ziac.PublicOutput([]const u8).known("123456789"),
        .endpoint_service_id = ziac.PublicOutput([]const u8).known("service-1"),
        .region = "europe-west1",
    });
}

fn clusterState() !ziac.InMemoryStateStore {
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    errdefer state.deinit();
    try state.put(.{
        .resource_id = "cockroach.Cluster.ziac-prod",
        .provider = .cockroach,
        .type_name = "cockroach.Cluster",
        .logical_id = "ziac-prod",
        .desired_hash = "hash",
        .outputs = &.{.{ .name = "cluster_id", .value = .{ .string = "cluster-1" } }},
        .status = .created,
    });
    return state;
}

fn clusterResponse(comptime plan: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"id\":\"cluster-1\",\"name\":\"ziac-prod\",\"cloud_provider\":\"GCP\",\"plan\":\"" ++ plan ++ "\",\"state\":\"CREATED\",\"delete_protection\":\"ENABLED\",\"sql_dns\":\"sql.example\",\"regions\":[{\"name\":\"europe-west1\",\"sql_dns\":\"sql.eu.example\",\"internal_dns\":\"internal.eu.example\",\"private_endpoint_dns\":\"private.eu.example\",\"ui_dns\":\"ui.eu.example\",\"node_count\":3,\"primary\":true}],\"config\":{}}" };
}

fn servicesResponse(comptime status: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"services\":[{\"availability_zone_ids\":[\"europe-west1-b\"],\"cloud_provider\":\"GCP\",\"endpoint_service_id\":\"service-1\",\"name\":\"projects/crl-prod/regions/europe-west1/serviceAttachments/crdb-1\",\"region_name\":\"europe-west1\",\"status\":\"" ++ status ++ "\"}]}" };
}

fn emptyServicesResponse() zstd.Http.Response {
    return .{ .status = 200, .body = "{\"services\":[]}" };
}

fn connectionsResponse(comptime service_id: ?[]const u8, comptime status: []const u8) zstd.Http.Response {
    const connection = if (service_id) |id|
        "{\"cloud_provider\":\"GCP\",\"endpoint_id\":\"123456789\",\"endpoint_service_id\":\"" ++ id ++ "\",\"region_name\":\"europe-west1\",\"service_name\":\"projects/crl-prod/regions/europe-west1/serviceAttachments/crdb-1\",\"status\":\"" ++ status ++ "\"}"
    else
        "";
    return .{ .status = 200, .body = "{\"connections\":[" ++ connection ++ "]}" };
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.string;
    unreachable;
}
