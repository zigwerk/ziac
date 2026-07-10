const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const cockroach = ziac.cockroach.client;
const cluster_mod = ziac.cockroach.cluster;

test "managed Cockroach cluster lifecycle polls scales imports and confirms delete" {
    const responses = [_]zstd.Http.Response{
        standardResponse("CREATING", true, 4),
        standardResponse("LOCKED", true, 4),
        standardResponse("CREATED", true, 4),
        standardResponse("CREATED", true, 4),
        standardResponse("LOCKED", false, 8),
        standardResponse("CREATED", false, 8),
        standardResponse("CREATED", false, 8),
        standardResponse("CREATED", false, 8),
        .{ .status = 204, .body = "" },
        .{ .status = 404, .body = "{\"message\":\"missing\"}" },
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var original = try standardCluster(4, true);
    defer original.deinit(std.testing.allocator);
    var scaled = try standardCluster(8, false);
    defer scaled.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;
    context.deadline_millis = 60_000;

    var absent = try live.readWithContext(&context, original.node);
    defer absent.deinit();
    try std.testing.expect(absent == .absent);
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);

    var created = try live.createWithContext(&context, original.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("cluster-1", created.physical_id);
    try std.testing.expectEqual(original.node.inputs_hash, created.observed_hash);
    try std.testing.expectEqualStrings("CREATED", outputString(created, "state"));
    try std.testing.expect(outputBoolean(created, "delete_protection"));
    context.physical_id = created.physical_id;

    var current = try live.readWithContext(&context, original.node);
    defer current.deinit();
    try std.testing.expect(current == .present);
    var update_diff = try live.diffWithContext(&context, scaled.node, &current.present);
    defer update_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, update_diff.kind);

    var updated = try live.updateWithContext(&context, scaled.node, &current.present);
    defer updated.deinit();
    try std.testing.expectEqual(scaled.node.inputs_hash, updated.observed_hash);
    try std.testing.expect(!outputBoolean(updated, "delete_protection"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "\"delete_protection\":\"DISABLED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "\"provisioned_virtual_cpus\":\"8\"") != null);

    var imported = try live.importWithContext(&context, scaled.node, "cluster-1");
    defer imported.deinit();
    try std.testing.expectEqual(scaled.node.inputs_hash, imported.observed_hash);
    try std.testing.expectError(
        error.DestructiveConfirmationRequired,
        live.deleteWithContext(&context, scaled.node, "cluster-1"),
    );
    context.destructive_confirmation = true;
    try live.deleteWithContext(&context, scaled.node, "cluster-1");
    var gone = try live.readWithContext(&context, scaled.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    try std.testing.expectEqual(@as(u64, 15_000), clock.nowMs());
    try std.testing.expectEqualStrings("DELETE", harness.transport.requests.items[8].method);
}

test "managed Cockroach cluster diff separates mutable scaling from replacement" {
    const responses = [_]zstd.Http.Response{
        standardTwoRegionResponse(),
        advancedResponse(3, 4),
        advancedResponse(3, 4),
        advancedResponse(3, 4),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.physical_id = "cluster-1";

    var one_region = try cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .standard = .{
            .regions = &.{.{ .name = "europe-west1" }},
            .provisioned_virtual_cpus = 4,
        } },
    });
    defer one_region.deinit(std.testing.allocator);
    var serverless = try live.readWithContext(&context, one_region.node);
    defer serverless.deinit();
    var remove_region = try live.diffWithContext(&context, one_region.node, &serverless.present);
    defer remove_region.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, remove_region.kind);

    var advanced_scaled = try cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .advanced = .{
            .regions = &.{.{ .name = "europe-west1", .node_count = 5 }},
            .num_virtual_cpus = 8,
            .storage_gib = 500,
        } },
    });
    defer advanced_scaled.deinit(std.testing.allocator);
    var advanced = try live.readWithContext(&context, advanced_scaled.node);
    defer advanced.deinit();
    var scale = try live.diffWithContext(&context, advanced_scaled.node, &advanced.present);
    defer scale.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, scale.kind);

    var private_advanced = try cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .advanced = .{
            .regions = &.{.{ .name = "europe-west1", .node_count = 3 }},
            .num_virtual_cpus = 4,
            .storage_gib = 500,
            .private_network_visibility = true,
            .cidr_range = "172.28.0.0/14",
        } },
    });
    defer private_advanced.deinit(std.testing.allocator);
    var public_advanced = try live.readWithContext(&context, private_advanced.node);
    defer public_advanced.deinit();
    var network_replacement = try live.diffWithContext(&context, private_advanced.node, &public_advanced.present);
    defer network_replacement.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, network_replacement.kind);

    var standard_desired = try standardCluster(4, true);
    defer standard_desired.deinit(std.testing.allocator);
    var advanced_drift = try live.readWithContext(&context, standard_desired.node);
    defer advanced_drift.deinit();
    var tier_replacement = try live.diffWithContext(&context, standard_desired.node, &advanced_drift.present);
    defer tier_replacement.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, tier_replacement.kind);
}

test "managed Cockroach cluster fails fast on terminal readiness and remote protection" {
    const failed_responses = [_]zstd.Http.Response{
        standardResponse("CREATING", true, 4),
        standardResponse("CREATION_FAILED", true, 4),
    };
    var failed_harness: Harness = undefined;
    failed_harness.init(&failed_responses);
    defer failed_harness.deinit();
    var protected = try standardCluster(4, true);
    defer protected.deinit(std.testing.allocator);
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;
    try std.testing.expectError(error.ProviderBug, failed_harness.live.provider().createWithContext(&context, protected.node));

    const protected_responses = [_]zstd.Http.Response{standardResponse("CREATED", true, 4)};
    var protected_harness: Harness = undefined;
    protected_harness.init(&protected_responses);
    defer protected_harness.deinit();
    var unprotected = try standardCluster(4, false);
    defer unprotected.deinit(std.testing.allocator);
    var delete_context = ziac.provider.OperationContext.init(std.testing.allocator);
    delete_context.destructive_confirmation = true;
    try std.testing.expectError(
        error.InvalidConfiguration,
        protected_harness.live.provider().deleteWithContext(&delete_context, unprotected.node, "cluster-1"),
    );
    try std.testing.expectEqual(@as(usize, 1), protected_harness.transport.requests.items.len);
}

test "managed Cockroach readiness polling obeys the operation deadline" {
    const responses = [_]zstd.Http.Response{standardResponse("CREATING", true, 4)};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var cluster = try standardCluster(4, true);
    defer cluster.deinit(std.testing.allocator);
    var clock = ziac.fx.Clock.fake(0);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.clock = &clock;
    context.deadline_millis = 4_000;

    try std.testing.expectError(error.ProviderTimeout, harness.live.provider().createWithContext(&context, cluster.node));
    try std.testing.expectEqual(@as(usize, 1), harness.transport.requests.items.len);
}

const Harness = struct {
    transport: @import("cockroach_client_test.zig").RecordingTransport,
    client: cockroach.Client,
    live: ziac.cockroach.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.transport = @import("cockroach_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = cockroach.Client.init(self.transport.client(), "dummy-key", .{
            .base_url = "https://cockroach.example.test/api",
        });
        self.live = ziac.cockroach.live_provider.LiveProvider.init(&self.client);
        self.live.cluster_poll_interval_millis = 5_000;
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.* = undefined;
    }
};

fn standardCluster(cpus: u16, protect: bool) !cluster_mod.Cluster {
    return cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .protect = protect,
        .plan = .{ .standard = .{
            .regions = &.{.{ .name = "europe-west1" }},
            .provisioned_virtual_cpus = cpus,
        } },
    });
}

fn standardResponse(comptime cluster_state: []const u8, comptime protect: bool, comptime cpus: comptime_int) zstd.Http.Response {
    return .{ .status = 200, .body = clusterJson(
        "STANDARD",
        cluster_state,
        if (protect) "ENABLED" else "DISABLED",
        "{\"serverless\":{\"routing_id\":\"route-1\",\"upgrade_type\":\"AUTOMATIC\",\"usage_limits\":{\"provisioned_virtual_cpus\":\"" ++ std.fmt.comptimePrint("{d}", .{cpus}) ++ "\"}}}",
        "[{\"name\":\"europe-west1\",\"sql_dns\":\"sql.example\",\"internal_dns\":\"internal.example\",\"private_endpoint_dns\":\"private.example\",\"ui_dns\":\"ui.example\",\"node_count\":0,\"primary\":true}]",
    ) };
}

fn standardTwoRegionResponse() zstd.Http.Response {
    return .{ .status = 200, .body = clusterJson(
        "STANDARD",
        "CREATED",
        "ENABLED",
        "{\"serverless\":{\"routing_id\":\"route-1\",\"upgrade_type\":\"AUTOMATIC\",\"usage_limits\":{\"provisioned_virtual_cpus\":\"4\"}}}",
        "[{\"name\":\"europe-west1\",\"sql_dns\":\"sql.eu\",\"internal_dns\":\"internal.eu\",\"private_endpoint_dns\":\"private.eu\",\"ui_dns\":\"ui.eu\",\"node_count\":0,\"primary\":true},{\"name\":\"us-central1\",\"sql_dns\":\"sql.us\",\"internal_dns\":\"internal.us\",\"private_endpoint_dns\":\"private.us\",\"ui_dns\":\"ui.us\",\"node_count\":0}]",
    ) };
}

fn advancedResponse(comptime nodes: comptime_int, comptime cpus: comptime_int) zstd.Http.Response {
    return .{ .status = 200, .body = clusterJson(
        "ADVANCED",
        "CREATED",
        "ENABLED",
        "{\"dedicated\":{\"num_virtual_cpus\":" ++ std.fmt.comptimePrint("{d}", .{cpus}) ++ ",\"storage_gib\":500}}",
        "[{\"name\":\"europe-west1\",\"sql_dns\":\"sql.example\",\"internal_dns\":\"internal.example\",\"private_endpoint_dns\":\"private.example\",\"ui_dns\":\"ui.example\",\"node_count\":" ++ std.fmt.comptimePrint("{d}", .{nodes}) ++ "}]",
    ) };
}

fn clusterJson(
    comptime plan: []const u8,
    comptime cluster_state: []const u8,
    comptime protection: []const u8,
    comptime config: []const u8,
    comptime regions: []const u8,
) []const u8 {
    return "{\"id\":\"cluster-1\",\"name\":\"ziac-prod\",\"cloud_provider\":\"GCP\",\"plan\":\"" ++ plan ++ "\",\"state\":\"" ++ cluster_state ++ "\",\"delete_protection\":\"" ++ protection ++ "\",\"cockroach_version\":\"v26.1.4\",\"sql_dns\":\"sql.example\",\"config\":" ++ config ++ ",\"regions\":" ++ regions ++ "}";
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.string;
    unreachable;
}

fn outputBoolean(result: ziac.provider.ResourceResult, name: []const u8) bool {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.boolean;
    unreachable;
}
