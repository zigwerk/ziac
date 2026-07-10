const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

const config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "live Cloud DNS provider manages and imports record sets in an existing zone" {
    var original = try ziac.gcp.dns.RecordSet.build(std.testing.allocator, config, .{
        .zone = "example-com",
        .name = "api.example.com.",
        .record_type = .a,
        .ttl = 60,
        .rrdatas = &.{"203.0.113.10"},
    });
    defer original.deinit(std.testing.allocator);
    var changed = try ziac.gcp.dns.RecordSet.build(std.testing.allocator, config, .{
        .zone = "example-com",
        .name = "api.example.com.",
        .record_type = .a,
        .ttl = 300,
        .rrdatas = &.{"203.0.113.11"},
    });
    defer changed.deinit(std.testing.allocator);
    const responses = [_]zstd.Http.Response{
        notFound(),
        recordResponse(60, "203.0.113.10"),
        recordResponse(300, "203.0.113.11"),
        .{ .status = 200, .body = "{}" },
        notFound(),
        recordResponse(300, "203.0.113.11"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var before = try provider.readWithContext(&context, original.node);
    defer before.deinit();
    try std.testing.expect(before == .absent);
    var created = try provider.createWithContext(&context, original.node);
    defer created.deinit();
    try std.testing.expect(created.completed);
    try std.testing.expectEqualStrings(
        "projects/ziac-dev/managedZones/example-com/rrsets/A/api.example.com.",
        created.physical_id,
    );
    var noop = try provider.diffWithContext(&context, original.node, &created);
    defer noop.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, noop.kind);
    var update = try provider.diffWithContext(&context, changed.node, &created);
    defer update.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, update.kind);
    var updated = try provider.updateWithContext(&context, changed.node, &created);
    defer updated.deinit();
    try std.testing.expectEqual(changed.node.inputs_hash, updated.observed_hash);
    try provider.deleteWithContext(&context, changed.node, updated.physical_id);
    var gone = try provider.readWithContext(&context, changed.node);
    defer gone.deinit();
    try std.testing.expect(gone == .absent);
    var imported = try provider.importWithContext(&context, changed.node, updated.physical_id);
    defer imported.deinit();
    try std.testing.expectEqualStrings("api.example.com.", outputString(imported, "fqdn"));
    try std.testing.expectEqualStrings("A", outputString(imported, "record_type"));

    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/dns/v1/projects/ziac-dev/managedZones/example-com/rrsets"));
    try std.testing.expectEqualStrings("PATCH", harness.transport.requests.items[2].method);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[2].url, "/dns/v1/projects/ziac-dev/managedZones/example-com/rrsets/api.example.com./A"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "203.0.113.11") != null);
    try std.testing.expectEqualStrings("DELETE", harness.transport.requests.items[3].method);
}

test "Cloud DNS identity changes require replacement" {
    var a_record = try ziac.gcp.dns.RecordSet.build(std.testing.allocator, config, .{
        .zone = "example-com",
        .name = "api.example.com.",
        .record_type = .a,
        .rrdatas = &.{"203.0.113.10"},
    });
    defer a_record.deinit(std.testing.allocator);
    var aaaa_record = try ziac.gcp.dns.RecordSet.build(std.testing.allocator, config, .{
        .zone = "example-com",
        .name = "api.example.com.",
        .record_type = .aaaa,
        .rrdatas = &.{"2001:db8::1"},
    });
    defer aaaa_record.deinit(std.testing.allocator);
    const responses = [_]zstd.Http.Response{recordResponse(300, "203.0.113.10")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var observed = try provider.readWithContext(&context, a_record.node);
    defer observed.deinit();
    var diff = try provider.diffWithContext(&context, aaaa_record.node, &observed.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, diff.kind);
}

test "Cloud DNS delete refuses a physical identity outside the declaration" {
    var record = try ziac.gcp.dns.RecordSet.build(std.testing.allocator, config, .{
        .zone = "example-com",
        .name = "api.example.com.",
        .record_type = .a,
        .rrdatas = &.{"203.0.113.10"},
    });
    defer record.deinit(std.testing.allocator);
    const responses = [_]zstd.Http.Response{};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidConfiguration,
        provider.deleteWithContext(
            &context,
            record.node,
            "projects/other-project/managedZones/example-com/rrsets/A/api.example.com.",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

test "Cloud DNS resolves typed record data from dependency state" {
    const address = ziac.Output([]const u8, .public).fromResource("gcp.compute.GlobalAddress.api-ip", "address");
    var record = try ziac.gcp.dns.RecordSet.build(std.testing.allocator, config, .{
        .zone = "example-com",
        .name = "api.example.com.",
        .record_type = .a,
        .rrdata_outputs = &.{address},
    });
    defer record.deinit(std.testing.allocator);
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "gcp.compute.GlobalAddress.api-ip",
        .type_name = "gcp.compute.GlobalAddress",
        .logical_id = "api-ip",
        .desired_hash = "address-hash",
        .outputs = &.{.{ .name = "address", .value = .{ .string = "203.0.113.10" } }},
        .status = .created,
    });
    const responses = [_]zstd.Http.Response{recordResponse(300, "203.0.113.10")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const provider = harness.live.provider();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = &state;

    var created = try provider.createWithContext(&context, record.node);
    defer created.deinit();
    try std.testing.expectEqual(record.node.inputs_hash, created.observed_hash);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "203.0.113.10") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "$output") == null);
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .dns = "https://dns.example.test" });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
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

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.string;
    unreachable;
}

fn notFound() zstd.Http.Response {
    return .{ .status = 404, .body = "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"missing\"}}" };
}

fn recordResponse(comptime ttl: u32, comptime address: []const u8) zstd.Http.Response {
    return .{
        .status = 200,
        .body = std.fmt.comptimePrint("{{\"name\":\"api.example.com.\",\"type\":\"A\",\"ttl\":{d},\"rrdatas\":[\"{s}\"]}}", .{ ttl, address }),
    };
}
