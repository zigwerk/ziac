const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const cockroach = ziac.cockroach.client;

test "Cockroach authorized network lifecycle resolves only the reserved address" {
    const responses = [_]zstd.Http.Response{
        allowlist(false, false),
        ok(),
        allowlist(true, false),
        ok(),
        okNoContent(),
        allowlist(false, false),
        allowlist(true, true),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var original = try rule(false);
    defer original.deinit(std.testing.allocator);
    var changed = try rule(true);
    defer changed.deinit(std.testing.allocator);
    var store = try addressState();
    defer store.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = &store;

    var before = try provider.readWithContext(&context, original.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try provider.createWithContext(&context, original.node);
    defer created.deinit();
    try std.testing.expectEqualStrings(
        "clusters/cluster-1/networking/allowlist/203.0.113.10/32",
        created.physical_id,
    );
    var present = try provider.readWithContext(&context, original.node);
    defer present.deinit();
    try std.testing.expectEqual(original.node.inputs_hash, present.present.observed_hash);
    var diff = try provider.diffWithContext(&context, changed.node, &present.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var updated = try provider.updateWithContext(&context, changed.node, &present.present);
    defer updated.deinit();
    try std.testing.expectEqual(changed.node.inputs_hash, updated.observed_hash);
    try provider.deleteWithContext(&context, changed.node, updated.physical_id);
    var gone = try provider.readWithContext(&context, changed.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try provider.importWithContext(&context, changed.node, updated.physical_id);
    defer imported.deinit();
    try std.testing.expectEqualStrings("203.0.113.10/32", imported.outputs[0].value.string);

    try std.testing.expectEqualStrings("PUT", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/networking/allowlist/203.0.113.10/32"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "203.0.113.11") == null);
    try std.testing.expectEqualStrings("PATCH", harness.transport.requests.items[3].method);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"ui\":true") != null);
}

const Harness = struct {
    transport: @import("cockroach_client_test.zig").RecordingTransport,
    client: cockroach.Client,
    live: ziac.cockroach.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.transport = @import("cockroach_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = cockroach.Client.init(self.transport.client(), "dummy-key", .{});
        self.live = ziac.cockroach.live_provider.LiveProvider.init(&self.client);
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.* = undefined;
    }
};

fn rule(ui: bool) !ziac.cockroach.authorized_network.AuthorizedNetwork {
    return ziac.cockroach.authorized_network.AuthorizedNetwork.build(std.testing.allocator, .{}, .{
        .name = "api-europe-west1",
        .cluster_id = "cluster-1",
        .ip_address = ziac.PublicOutput([]const u8).fromResource(
            "gcp.compute.RegionalAddress.europe-west1.api-europe-west1",
            "address",
        ),
        .ui = ui,
    });
}

fn addressState() !ziac.InMemoryStateStore {
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    errdefer store.deinit();
    try store.put(.{
        .resource_id = "gcp.compute.RegionalAddress.europe-west1.api-europe-west1",
        .provider = .gcp,
        .type_name = "gcp.compute.RegionalAddress",
        .logical_id = "api-europe-west1",
        .desired_hash = "hash",
        .outputs = &.{.{ .name = "address", .value = .{ .string = "203.0.113.10" } }},
        .status = .created,
    });
    return store;
}

fn allowlist(comptime include: bool, comptime ui: bool) zstd.Http.Response {
    const entry = if (include)
        "{\"cidr_ip\":\"203.0.113.10\",\"cidr_mask\":32,\"name\":\"api-europe-west1\",\"sql\":true,\"ui\":" ++ (if (ui) "true" else "false") ++ "}"
    else
        "";
    return .{ .status = 200, .body = "{\"allowlist\":[" ++ entry ++ "],\"propagating\":false}" };
}

fn ok() zstd.Http.Response {
    return .{ .status = 200, .body = "{}" };
}

fn okNoContent() zstd.Http.Response {
    return .{ .status = 204, .body = "" };
}
