const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "Cloud SQL primary declares protected private PostgreSQL with typed policy" {
    const flags = [_]ziac.gcp.sql.DatabaseFlag{
        .{ .name = "cloudsql.iam_authentication", .value = "on" },
        .{ .name = "log_min_duration_statement", .value = "500" },
    };
    var instance = try ziac.gcp.sql.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "orders-primary",
        .database_version = .postgres_17,
        .region = "europe-west1",
        .tier = "db-custom-2-7680",
        .availability = .regional,
        .disk_size_gb = 50,
        .point_in_time_recovery = true,
        .private_network = "projects/host/global/networks/platform",
        .allocated_ip_range = "cloudsql-range",
        .enable_private_path = true,
        .ssl_mode = .encrypted_only,
        .database_flags = &flags,
    });
    defer instance.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.sql.Instance", instance.node.type_name);
    try std.testing.expect(instance.node.lifecycle.protect);
    try std.testing.expect(instance.node.lifecycle.retain_on_delete);
    try std.testing.expectEqualStrings("POSTGRES_17", inputString(instance.node, "database_version").?);
    try std.testing.expectEqualStrings("projects/host/global/networks/platform", inputString(instance.node, "private_network").?);
    try std.testing.expectEqualStrings("ENCRYPTED_ONLY", inputString(instance.node, "ssl_mode").?);
    try std.testing.expectEqual(@as(i64, 50), inputInteger(instance.node, "disk_size_gb").?);
    try std.testing.expect(instance.connection_name == .resource_ref);
    try std.testing.expect(instance.private_ip == .resource_ref);
}

test "Cloud SQL rejects contradictory public private and connector networking" {
    try std.testing.expectError(error.InvalidNetworkConfiguration, ziac.gcp.sql.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "orders",
        .database_version = .postgres_17,
        .region = "europe-west1",
        .tier = "db-custom-2-7680",
        .authorized_networks = &.{.{ .name = "office", .cidr = "203.0.113.0/24" }},
    }));
    try std.testing.expectError(error.InvalidNetworkConfiguration, ziac.gcp.sql.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "orders",
        .database_version = .postgres_17,
        .region = "europe-west1",
        .tier = "db-custom-2-7680",
        .ipv4_enabled = true,
        .connector_enforcement = .required,
        .authorized_networks = &.{.{ .name = "office", .cidr = "203.0.113.0/24" }},
    }));
    try std.testing.expectError(error.InvalidNetworkConfiguration, ziac.gcp.sql.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "orders",
        .database_version = .postgres_17,
        .region = "europe-west1",
        .tier = "db-custom-2-7680",
        .enable_private_path = true,
    }));
}

test "Cloud SQL canonicalizes unordered policies and validates maintenance windows" {
    const first_flags = [_]ziac.gcp.sql.DatabaseFlag{
        .{ .name = "log_min_duration_statement", .value = "500" },
        .{ .name = "cloudsql.iam_authentication", .value = "on" },
    };
    const second_flags = [_]ziac.gcp.sql.DatabaseFlag{
        .{ .name = "cloudsql.iam_authentication", .value = "on" },
        .{ .name = "log_min_duration_statement", .value = "500" },
    };
    const first_networks = [_]ziac.gcp.sql.AuthorizedNetwork{
        .{ .name = "office-b", .cidr = "203.0.113.128/25" },
        .{ .name = "office-a", .cidr = "203.0.113.0/25" },
    };
    const second_networks = [_]ziac.gcp.sql.AuthorizedNetwork{
        .{ .name = "office-a", .cidr = "203.0.113.0/25" },
        .{ .name = "office-b", .cidr = "203.0.113.128/25" },
    };
    var first = try ziac.gcp.sql.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "orders",
        .database_version = .postgres_17,
        .region = "europe-west1",
        .tier = "db-custom-2-7680",
        .ipv4_enabled = true,
        .database_flags = &first_flags,
        .authorized_networks = &first_networks,
    });
    defer first.deinit(std.testing.allocator);
    var second = try ziac.gcp.sql.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "orders",
        .database_version = .postgres_17,
        .region = "europe-west1",
        .tier = "db-custom-2-7680",
        .ipv4_enabled = true,
        .database_flags = &second_flags,
        .authorized_networks = &second_networks,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &first.node.inputs_hash, &second.node.inputs_hash);

    try std.testing.expectError(error.InvalidInstance, ziac.gcp.sql.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "orders",
        .database_version = .postgres_17,
        .region = "europe-west1",
        .tier = "db-custom-2-7680",
        .maintenance = .{ .day = 0, .hour = 24 },
    }));
}

test "Cloud SQL read replica is wired to its primary output" {
    var primary = try ziac.gcp.sql.Instance.build(std.testing.allocator, provider, .{
        .instance_id = "orders-primary",
        .database_version = .postgres_17,
        .region = "europe-west1",
        .tier = "db-custom-2-7680",
    });
    defer primary.deinit(std.testing.allocator);
    var replica = try ziac.gcp.sql.ReadReplica.build(std.testing.allocator, provider, .{
        .instance_id = "orders-replica",
        .primary_instance_id = primary.instance_id,
        .database_version = .postgres_17,
        .region = "us-central1",
        .tier = "db-custom-2-7680",
    });
    defer replica.deinit(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(primary.node);
    try graph.addResource(replica.node);
    try graph.validateAcyclic();
    try std.testing.expect(hasDependency(&graph, replica.node.id, primary.node.id));
    try std.testing.expectEqualStrings("gcp.sql.ReadReplica", replica.node.type_name);
}

test "Cloud SQL databases are retained and user auth modes protect secrets" {
    var database = try ziac.gcp.sql.Database.build(std.testing.allocator, provider, .{
        .instance_id = "orders-primary",
        .name = "orders",
    });
    defer database.deinit(std.testing.allocator);
    try std.testing.expect(database.node.lifecycle.retain_on_delete);

    const password = ziac.output.Output(ziac.value.SecretReference, .secret).known(.{
        .provider = "gcp-secret-manager",
        .resource = "projects/ziac-dev/secrets/orders-db-password",
        .version = "7",
    });
    var builtin = try ziac.gcp.sql.User.build(std.testing.allocator, provider, .{
        .instance_id = "orders-primary",
        .name = "app",
        .password = password,
    });
    defer builtin.deinit(std.testing.allocator);
    try std.testing.expect(inputValue(builtin.node, "password") == .secret_ref);

    try std.testing.expectError(error.PasswordRequired, ziac.gcp.sql.User.build(std.testing.allocator, provider, .{
        .instance_id = "orders-primary",
        .name = "app",
    }));
    try std.testing.expectError(error.PasswordForbidden, ziac.gcp.sql.User.build(std.testing.allocator, provider, .{
        .instance_id = "orders-primary",
        .name = "api@ziac-dev.iam",
        .user_type = .cloud_iam_service_account,
        .password = password,
    }));
}

test "Cloud SQL client certificate writes its private key to a declared secret" {
    var secret = try ziac.gcp.secret_manager.Secret.build(std.testing.allocator, provider, .{ .name = "orders-client-key" });
    defer secret.deinit(std.testing.allocator);
    var certificate = try ziac.gcp.sql.ClientCertificate.build(std.testing.allocator, provider, .{
        .instance_id = "orders-primary",
        .common_name = "orders-api",
        .private_key_secret = secret.resource_name,
    });
    defer certificate.deinit(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(secret.node);
    try graph.addResource(certificate.node);
    try graph.validateAcyclic();
    try std.testing.expect(hasDependency(&graph, certificate.node.id, secret.node.id));
    try std.testing.expect(certificate.private_key_version == .resource_ref);
    try std.testing.expectEqual(ziac.output.Secrecy.secret, @TypeOf(certificate.private_key_version).secrecy);
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    if (node.inputs != .object) unreachable;
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}

fn inputString(node: ziac.ResourceNode, name: []const u8) ?[]const u8 {
    return switch (inputValue(node, name)) {
        .string => |text| text,
        else => null,
    };
}

fn inputInteger(node: ziac.ResourceNode, name: []const u8) ?i64 {
    return switch (inputValue(node, name)) {
        .integer => |integer| integer,
        else => null,
    };
}

fn hasDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    return false;
}
