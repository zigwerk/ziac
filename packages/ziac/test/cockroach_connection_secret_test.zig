const std = @import("std");
const ziac = @import("ziac");

test "Cockroach connection URI percent encodes credentials and enforces verify-full" {
    const uri = try ziac.cockroach.connection_secret.connectionUriAlloc(std.testing.allocator, .{
        .host = "ziac-prod.cockroachlabs.cloud",
        .port = 26257,
        .database = "app/db",
        .username = "app user",
        .password = "p@ss:/?#[]",
    });
    defer {
        std.crypto.secureZero(u8, uri);
        std.testing.allocator.free(uri);
    }
    try std.testing.expectEqualStrings(
        "postgresql://app%20user:p%40ss%3A%2F%3F%23%5B%5D@ziac-prod.cockroachlabs.cloud:26257/app%2Fdb?sslmode=verify-full",
        uri,
    );
}

test "Cockroach connection payload uses an injectable secure password source" {
    var fixed = FixedPasswordSource{};
    var spec = try ziac.cockroach.connection_secret.PayloadSpec.initOwned(std.testing.allocator, .{
        .source_resource = "cockroach.ConnectionSecret.production",
        .host = ziac.PublicOutput([]const u8).known("ziac-prod.cockroachlabs.cloud"),
        .database = "app",
        .username = "app_user",
    });
    defer spec.deinit();
    var source = ziac.cockroach.connection_secret.ConnectionPayloadSource.init(&spec, fixed.source());
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var payload = try source.secretSource().resolve(&context, std.testing.allocator, .{
        .provider = "ziac-cockroach-connection",
        .resource = "cockroach.ConnectionSecret.production",
        .field = "uri",
    });
    defer payload.deinit();

    try std.testing.expectEqual(@as(usize, 1), fixed.calls);
    try std.testing.expectEqualStrings(
        "postgresql://app_user:p%40ss%3A%2F%3F%23%5B%5D@ziac-prod.cockroachlabs.cloud:26257/app?sslmode=verify-full",
        payload.bytes,
    );
}

test "ConnectionSecret builds secret-first graph and exposes only Secret Manager reference" {
    var component = try ziac.cockroach.connection_secret.ConnectionSecret.build(
        std.testing.allocator,
        .{ .project_id = "ziac-dev", .primary_region = "europe-west1" },
        .{},
        .{
            .name = "production",
            .cluster_id = "cluster-1",
            .plan = .standard,
            .regions = &.{ "europe-west1", "us-central1" },
            .database = "app",
            .username = "app_user",
            .secret_id = "database-url",
            .accessor_member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
        },
    );
    defer component.deinit();

    try std.testing.expectEqual(@as(usize, 5), component.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 5), component.graph.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "cockroach.Cluster.Existing"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.secret.Secret"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.secret.SecretVersion"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "cockroach.SqlUser"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.secret.SecretIamMember"));
    try std.testing.expect(component.secret_version == .resource_ref);
    try std.testing.expectEqual(ziac.output.Secrecy.secret, @TypeOf(component.secret_version).secrecy);
    try std.testing.expectEqualStrings("cockroach.ConnectionSecret.production", component.payload_spec.source_resource);
    try component.graph.validateAcyclic();

    const user = findType(&component.graph, "cockroach.SqlUser");
    try std.testing.expect(inputValue(user, "connection_secret") == .output_ref);
    const version = findType(&component.graph, "gcp.secret.SecretVersion");
    const version_json = try version.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(version_json);
    try std.testing.expect(std.mem.indexOf(u8, version_json, "p@ss") == null);
    try std.testing.expect(std.mem.indexOf(u8, version_json, "ziac-cockroach-connection") != null);

    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();
    try store.put(.{
        .resource_id = "cockroach.Cluster.Existing.production",
        .provider = .cockroach,
        .type_name = "cockroach.Cluster.Existing",
        .logical_id = "production",
        .physical_id = "cluster-1",
        .desired_hash = "hash",
        .outputs = &.{.{ .name = "sql_dns", .value = .{ .string = "ziac-prod.cockroachlabs.cloud" } }},
        .status = .adopted,
    });
    var fixed = FixedPasswordSource{};
    var generated = ziac.cockroach.connection_secret.ConnectionPayloadSource.init(&component.payload_spec, fixed.source());
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = &store;
    var payload = try generated.secretSource().resolve(&context, std.testing.allocator, .{
        .provider = "ziac-cockroach-connection",
        .resource = "cockroach.ConnectionSecret.production",
        .field = "uri",
    });
    defer payload.deinit();
    try std.testing.expect(std.mem.indexOf(u8, payload.bytes, "@ziac-prod.cockroachlabs.cloud:26257") != null);
}

const FixedPasswordSource = struct {
    calls: usize = 0,

    fn source(self: *FixedPasswordSource) ziac.cockroach.connection_secret.PasswordSource {
        return .{ .ptr = self, .generateFn = generate };
    }

    fn generate(raw: *anyopaque, allocator: std.mem.Allocator) ziac.cockroach.connection_secret.PasswordError!ziac.cockroach.connection_secret.Password {
        const self: *FixedPasswordSource = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return ziac.cockroach.connection_secret.Password.initOwned(allocator, "p@ss:/?#[]");
    }
};

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) {
        count += 1;
    };
    return count;
}

fn findType(graph: *const ziac.ResourceGraph, type_name: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return node;
    unreachable;
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
