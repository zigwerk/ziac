const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "Connectors provider checkpoints connection creation and serializes only secret references" {
    const operation_name = "projects/integration-prod/locations/europe-west1/operations/create-connection";
    const connection_json = "{\"name\":\"projects/integration-prod/locations/europe-west1/connections/crm\",\"connectorVersion\":\"projects/integration-prod/locations/global/providers/salesforce/connectors/salesforce/versions/1\",\"serviceAccount\":\"connectors@integration-prod.iam.gserviceaccount.com\",\"nodeConfig\":{\"minNodeCount\":1,\"maxNodeCount\":2},\"status\":{\"state\":\"ACTIVE\"},\"connectionRevision\":\"3\"}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"" ++ operation_name ++ "\"}"),
        ok("{\"name\":\"" ++ operation_name ++ "\",\"done\":true,\"response\":" ++ connection_json ++ "}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.connectors_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var connection = try buildConnection();
    defer connection.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, connection.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/projects/integration-prod/locations/europe-west1/connections?connectionId=crm&requestId=") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "projects/integration-prod/secrets/crm-password/versions/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "plain-text-password") == null);
    context.operation_handle = pending.operation_handle;
    var observed = try handler.read(&context, connection.node, pending.physical_id);
    defer observed.deinit();
    try std.testing.expectEqualStrings("projects/integration-prod/locations/europe-west1/connections/crm", observed.present.physical_id);
}

test "Regional settings is an update-only singleton" {
    const operation_name = "projects/integration-prod/locations/europe-west1/operations/settings";
    const responses = [_]zstd.Http.Response{ok("{\"name\":\"" ++ operation_name ++ "\"}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.connectors_provider.Handler{ .client = &harness.client };
    var settings = try ziac.gcp.connectors.RegionalSettings.build(std.testing.allocator, config(), .{ .location = "europe-west1", .egress_mode = .private_ip });
    defer settings.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var pending = try handler.create(&context, settings.node);
    defer pending.deinit();
    try std.testing.expectEqualStrings("PATCH", harness.transport.requests.items[0].method);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/projects/integration-prod/locations/europe-west1/regionalSettings?updateMask=networkConfig%2CencryptionConfig%2Cclient") != null);
    try std.testing.expectError(error.InvalidConfiguration, handler.delete(&context, settings.node, "projects/integration-prod/locations/europe-west1/regionalSettings"));
}

fn buildConnection() !ziac.gcp.connectors.Connection {
    return ziac.gcp.connectors.Connection.build(std.testing.allocator, config(), .{
        .name = "crm",
        .location = "europe-west1",
        .connector_version = "projects/integration-prod/locations/global/providers/salesforce/connectors/salesforce/versions/1",
        .service_account_email = "connectors@integration-prod.iam.gserviceaccount.com",
        .authentication = .{ .user_password = .{ .username = "runtime", .password_secret_version = .{ .value = "projects/integration-prod/secrets/crm-password/versions/3" } } },
    });
}
fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "integration-prod", .primary_region = "europe-west1" };
}
const Harness = struct {
    source: FixedTokenSource,
    cache: ziac.gcp.auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: ziac.gcp.client.Client,
    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = ziac.gcp.auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = ziac.gcp.client.Client.init(self.transport.client(), &self.cache, .{ .connectors = "https://connectors.example.test" });
    }
    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};
const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) ziac.gcp.auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) ziac.gcp.auth.AuthError!ziac.gcp.auth.AccessToken {
        return ziac.gcp.auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};
fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
