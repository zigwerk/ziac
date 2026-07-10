const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

const regions = [_][]const u8{"europe-west1"};
const config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .service_regions = &regions,
    .network_tier = .premium,
};

test "live GCP provider manages a reserved PSC address" {
    var address = try ziac.gcp.psc.Address.build(std.testing.allocator, config, .{
        .name = "api-db-eu",
        .region = "europe-west1",
        .subnetwork = ziac.PublicOutput([]const u8).known(
            "projects/ziac-dev/regions/europe-west1/subnetworks/api-db-eu",
        ),
    });
    defer address.deinit(std.testing.allocator);
    const json =
        "{\"name\":\"api-db-eu\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/addresses/api-db-eu\",\"address\":\"10.42.0.2\",\"addressType\":\"INTERNAL\",\"ipVersion\":\"IPV4\",\"subnetwork\":\"projects/ziac-dev/regions/europe-west1/subnetworks/api-db-eu\"}";
    const responses = lifecycleResponses(json);
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();

    try exerciseLifecycle(&harness, address.node, "address", "10.42.0.2");
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.transport.requests.items[1].url,
        "/projects/ziac-dev/regions/europe-west1/addresses",
    ));
    try std.testing.expectEqualStrings(
        "{\"name\":\"api-db-eu\",\"addressType\":\"INTERNAL\",\"ipVersion\":\"IPV4\",\"subnetwork\":\"projects/ziac-dev/regions/europe-west1/subnetworks/api-db-eu\"}",
        harness.transport.requests.items[1].body,
    );
}

test "live GCP provider creates PSC endpoint without waiting for acceptance" {
    var endpoint = try ziac.gcp.psc.Endpoint.build(std.testing.allocator, config, .{
        .name = "api-db-eu",
        .region = "europe-west1",
        .network = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/api-db"),
        .address = ziac.PublicOutput([]const u8).known("10.42.0.2"),
        .address_resource = ziac.PublicOutput([]const u8).known(
            "projects/ziac-dev/regions/europe-west1/addresses/api-db-eu",
        ),
        .target = ziac.PublicOutput([]const u8).known(
            "projects/crl-prod/regions/europe-west1/serviceAttachments/crdb-1",
        ),
    });
    defer endpoint.deinit(std.testing.allocator);
    const json =
        "{\"name\":\"api-db-eu\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/forwardingRules/api-db-eu\",\"IPAddress\":\"10.42.0.2\",\"allowPscGlobalAccess\":true,\"loadBalancingScheme\":\"\",\"network\":\"projects/ziac-dev/global/networks/api-db\",\"noAutomateDnsZone\":true,\"target\":\"projects/crl-prod/regions/europe-west1/serviceAttachments/crdb-1\",\"pscConnectionId\":\"123456789\",\"pscConnectionStatus\":\"PENDING\"}";
    const responses = lifecycleResponses(json);
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();

    try exerciseLifecycle(&harness, endpoint.node, "psc_connection_id", "123456789");
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.transport.requests.items[1].url,
        "/projects/ziac-dev/regions/europe-west1/forwardingRules",
    ));
    try std.testing.expectEqualStrings(
        "{\"name\":\"api-db-eu\",\"IPAddress\":\"projects/ziac-dev/regions/europe-west1/addresses/api-db-eu\",\"allowPscGlobalAccess\":true,\"loadBalancingScheme\":\"\",\"network\":\"projects/ziac-dev/global/networks/api-db\",\"noAutomateDnsZone\":true,\"target\":\"projects/crl-prod/regions/europe-west1/serviceAttachments/crdb-1\"}",
        harness.transport.requests.items[1].body,
    );
}

test "live GCP provider rejects resolved PSC resources outside the configured project or region" {
    var address = try ziac.gcp.psc.Address.build(std.testing.allocator, config, .{
        .name = "api-db-eu",
        .region = "europe-west1",
        .subnetwork = ziac.PublicOutput([]const u8).fromResource("gcp.compute.Subnetwork.other", "self_link"),
    });
    defer address.deinit(std.testing.allocator);
    var address_state = try outputState(
        "gcp.compute.Subnetwork.other",
        "self_link",
        "projects/other-project/regions/europe-west1/subnetworks/api-db-eu",
    );
    defer address_state.deinit();
    const no_responses = [_]zstd.Http.Response{};
    var address_harness: Harness = undefined;
    address_harness.init(&no_responses);
    defer address_harness.deinit();
    var address_context = ziac.provider.OperationContext.init(std.testing.allocator);
    address_context.state = &address_state;
    try std.testing.expectError(
        error.InvalidConfiguration,
        address_harness.live.provider().createWithContext(&address_context, address.node),
    );
    try std.testing.expectEqual(@as(usize, 0), address_harness.transport.requests.items.len);

    var endpoint = try ziac.gcp.psc.Endpoint.build(std.testing.allocator, config, .{
        .name = "api-db-eu",
        .region = "europe-west1",
        .network = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/api-db"),
        .address = ziac.PublicOutput([]const u8).known("10.42.0.2"),
        .address_resource = ziac.PublicOutput([]const u8).known(
            "projects/ziac-dev/regions/europe-west1/addresses/api-db-eu",
        ),
        .target = ziac.PublicOutput([]const u8).fromResource(
            "cockroach.PrivateEndpointService.api-db.europe-west1",
            "service_attachment",
        ),
    });
    defer endpoint.deinit(std.testing.allocator);
    var target_state = try outputState(
        "cockroach.PrivateEndpointService.api-db.europe-west1",
        "service_attachment",
        "projects/crl-prod/regions/us-central1/serviceAttachments/crdb-1",
    );
    defer target_state.deinit();
    var endpoint_harness: Harness = undefined;
    endpoint_harness.init(&no_responses);
    defer endpoint_harness.deinit();
    var endpoint_context = ziac.provider.OperationContext.init(std.testing.allocator);
    endpoint_context.state = &target_state;
    try std.testing.expectError(
        error.InvalidConfiguration,
        endpoint_harness.live.provider().createWithContext(&endpoint_context, endpoint.node),
    );
    try std.testing.expectEqual(@as(usize, 0), endpoint_harness.transport.requests.items.len);
}

test "live GCP provider rejects a PSC physical identity outside the declaration" {
    var address = try ziac.gcp.psc.Address.build(std.testing.allocator, config, .{
        .name = "api-db-eu",
        .region = "europe-west1",
        .subnetwork = ziac.PublicOutput([]const u8).known(
            "projects/ziac-dev/regions/europe-west1/subnetworks/api-db-eu",
        ),
    });
    defer address.deinit(std.testing.allocator);
    const no_responses = [_]zstd.Http.Response{};
    var harness: Harness = undefined;
    harness.init(&no_responses);
    defer harness.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const foreign_id = "projects/other-project/regions/europe-west1/addresses/api-db-eu";

    try std.testing.expectError(
        error.InvalidConfiguration,
        provider.importWithContext(&context, address.node, foreign_id),
    );
    try std.testing.expectError(
        error.InvalidConfiguration,
        provider.deleteWithContext(&context, address.node, foreign_id),
    );
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

fn exerciseLifecycle(
    harness: *Harness,
    node: ziac.ResourceNode,
    output_name: []const u8,
    output_value: []const u8,
) !void {
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var before = try provider.readWithContext(&context, node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var creating = try provider.createWithContext(&context, node);
    defer creating.deinit();
    try std.testing.expect(!creating.completed);
    context.physical_id = creating.physical_id;
    context.operation_handle = creating.operation_handle;
    var present = try provider.readWithContext(&context, node);
    defer present.deinit();
    try std.testing.expectEqual(node.inputs_hash, present.present.observed_hash);
    try std.testing.expectEqualStrings(output_value, outputString(present.present, output_name));
    context.operation_handle = null;
    try provider.deleteWithContext(&context, node, creating.physical_id);
    var gone = try provider.readWithContext(&context, node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try provider.importWithContext(&context, node, creating.physical_id);
    defer imported.deinit();
    try std.testing.expectEqualStrings(creating.physical_id, imported.physical_id);
}

const Harness = struct {
    token_source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    live: ziac.gcp.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.token_source = .{};
        self.cache = auth.TokenCache.init(self.token_source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .compute = "https://compute.example.test" });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
        self.live.operation_policy = .{ .poll_interval_millis = 1 };
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{
            .access_token = "dummy-google-token",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 3_600,
        });
    }
};

fn lifecycleResponses(comptime resource_json: []const u8) [8]zstd.Http.Response {
    return .{
        notFound(),
        operation("insert-psc"),
        done("insert-psc"),
        .{ .status = 200, .body = resource_json },
        operation("delete-psc"),
        done("delete-psc"),
        notFound(),
        .{ .status = 200, .body = resource_json },
    };
}

fn outputState(resource_id: []const u8, name: []const u8, output_value: []const u8) !ziac.InMemoryStateStore {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    errdefer store.deinit();
    try store.put(.{
        .resource_id = resource_id,
        .provider = .gcp,
        .type_name = "fixture",
        .logical_id = "fixture",
        .desired_hash = "fixture",
        .outputs = &.{.{ .name = name, .value = .{ .string = output_value } }},
        .status = .created,
    });
    return store;
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" };
}

fn operation(comptime name: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"name\":\"" ++ name ++ "\"}" };
}

fn done(comptime name: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = "{\"name\":\"" ++ name ++ "\",\"status\":\"DONE\"}" };
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.string;
    unreachable;
}
