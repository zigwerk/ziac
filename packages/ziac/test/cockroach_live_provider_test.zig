const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const cockroach = ziac.cockroach.client;

test "existing Cockroach cluster refresh detects changed topology and missing cluster" {
    const responses = [_]zstd.Http.Response{
        clusterResponse(&.{ "europe-west1", "us-central1" }),
        clusterResponse(&.{ "europe-west1", "asia-northeast1" }),
        notFound(),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var cluster = try ziac.cockroach.existing_cluster.ExistingCluster.build(std.testing.allocator, .{}, .{
        .name = "production",
        .cluster_id = "cluster-1",
        .plan = .standard,
        .regions = &.{ "europe-west1", "us-central1" },
    });
    defer cluster.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var current = try live.readWithContext(&context, cluster.node);
    defer current.deinit();
    try std.testing.expect(current == .present);
    var noop = try live.diffWithContext(&context, cluster.node, &current.present);
    defer noop.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, noop.kind);
    try std.testing.expectEqualStrings("ziac-prod.cockroachlabs.cloud", outputString(current.present, "sql_dns"));
    try std.testing.expectEqualStrings("ziac-prod.gcp-europe-west1.cockroachlabs.cloud", outputString(current.present, "primary_sql_dns"));

    var changed = try live.readWithContext(&context, cluster.node);
    defer changed.deinit();
    try std.testing.expect(changed == .present);
    var drift = try live.diffWithContext(&context, cluster.node, &changed.present);
    defer drift.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, drift.kind);
    try std.testing.expectEqual(@as(usize, 1), drift.reasons.len);
    try std.testing.expectEqualStrings(
        "regions: missing [us-central1]; unexpected [asia-northeast1]",
        drift.reasons[0],
    );
    try std.testing.expectError(error.InvalidConfiguration, live.updateWithContext(&context, cluster.node, &changed.present));

    var missing = try live.readWithContext(&context, cluster.node);
    defer missing.deinit();
    try std.testing.expect(missing == .absent);
    try std.testing.expectEqualStrings(
        "https://cockroach.example.test/api/v1/clusters/cluster-1",
        harness.transport.requests.items[0].url,
    );
}

test "existing Cockroach cluster create imports exact cluster and destroy only detaches state" {
    const responses = [_]zstd.Http.Response{
        clusterResponse(&.{ "europe-west1", "us-central1" }),
        clusterResponse(&.{ "europe-west1", "us-central1" }),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var cluster = try ziac.cockroach.existing_cluster.ExistingCluster.build(std.testing.allocator, .{}, .{
        .name = "production",
        .cluster_id = "cluster-1",
        .plan = .standard,
        .regions = &.{ "europe-west1", "us-central1" },
    });
    defer cluster.deinit(std.testing.allocator);
    const live = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try live.createWithContext(&context, cluster.node);
    defer created.deinit();
    try std.testing.expectEqualStrings("cluster-1", created.physical_id);
    var imported = try live.importWithContext(&context, cluster.node, "cluster-1");
    defer imported.deinit();
    try std.testing.expectEqual(cluster.node.inputs_hash, imported.observed_hash);

    const calls_before_delete = harness.transport.requests.items.len;
    try live.deleteWithContext(&context, cluster.node, "cluster-1");
    try std.testing.expectEqual(calls_before_delete, harness.transport.requests.items.len);
    try std.testing.expectError(error.InvalidConfiguration, live.importWithContext(&context, cluster.node, "cluster-other"));
}

test "refresh graph records Cockroach topology drift and taints a missing cluster" {
    const responses = [_]zstd.Http.Response{
        clusterResponse(&.{ "europe-west1", "asia-northeast1" }),
        notFound(),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var cluster = try ziac.cockroach.existing_cluster.ExistingCluster.build(std.testing.allocator, .{}, .{
        .name = "production",
        .cluster_id = "cluster-1",
        .plan = .standard,
        .regions = &.{ "europe-west1", "us-central1" },
    });
    defer cluster.deinit(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(cluster.node);
    const node = graph.resources.items[0];
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();
    const desired_hash = std.fmt.bytesToHex(node.inputs_hash, .lower);
    try store.put(.{
        .resource_id = node.id,
        .provider = node.provider,
        .type_name = node.type_name,
        .logical_id = node.logical_id,
        .physical_id = "cluster-1",
        .desired_hash = desired_hash[0..],
        .observed_hash = desired_hash[0..],
        .status = .created,
    });
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.cockroach, harness.live.provider());

    try ziac.refresh.refreshGraph(std.testing.allocator, &graph, &store, providers, null);
    const drifted = store.get(node.id).?;
    try std.testing.expectEqual(ziac.ResourceStatus.adopted, drifted.status);
    try std.testing.expect(!std.mem.eql(u8, drifted.desired_hash, drifted.observed_hash.?));
    try std.testing.expectEqualStrings("asia-northeast1,europe-west1", stateOutputString(drifted, "regions"));

    try ziac.refresh.refreshGraph(std.testing.allocator, &graph, &store, providers, null);
    try std.testing.expectEqual(ziac.ResourceStatus.tainted, store.get(node.id).?.status);
}

const Harness = struct {
    transport: @import("cockroach_client_test.zig").RecordingTransport,
    client: cockroach.Client,
    live: ziac.cockroach.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.transport = @import("cockroach_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = cockroach.Client.init(self.transport.client(), "dummy-cockroach-key", .{
            .base_url = "https://cockroach.example.test/api",
        });
        self.live = ziac.cockroach.live_provider.LiveProvider.init(&self.client);
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.* = undefined;
    }
};

fn clusterResponse(comptime regions: []const []const u8) zstd.Http.Response {
    comptime var region_json: []const u8 = "";
    inline for (regions, 0..) |region, index| {
        region_json = region_json ++ (if (index == 0) "" else ",") ++ std.fmt.comptimePrint(
            "{{\"name\":\"{s}\",\"sql_dns\":\"ziac-prod.gcp-{s}.cockroachlabs.cloud\",\"internal_dns\":\"internal-ziac-prod.gcp-{s}.cockroachlabs.cloud\",\"private_endpoint_dns\":\"private-ziac-prod.gcp-{s}.cockroachlabs.cloud\",\"ui_dns\":\"admin-ziac-prod.gcp-{s}.cockroachlabs.cloud\",\"node_count\":0{s}}}",
            .{ region, region, region, region, region, if (index == 0) ",\"primary\":true" else "" },
        );
    }
    return .{
        .status = 200,
        .body = "{\"id\":\"cluster-1\",\"name\":\"ziac-prod\",\"cloud_provider\":\"GCP\",\"plan\":\"STANDARD\",\"state\":\"CREATED\",\"sql_dns\":\"ziac-prod.cockroachlabs.cloud\",\"regions\":[" ++ region_json ++ "]}",
    };
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"message\":\"cluster not found\"}" };
}

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.string;
    unreachable;
}

fn stateOutputString(record: ziac.StateRecord, name: []const u8) []const u8 {
    for (record.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.string;
    unreachable;
}
