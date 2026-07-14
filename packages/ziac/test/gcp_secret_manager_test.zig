const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "Secret Manager resources retain references without retaining payloads" {
    var secret = try ziac.gcp.secret_manager.Secret.build(std.testing.allocator, provider, .{
        .name = "database-url",
    });
    defer secret.deinit(std.testing.allocator);
    var version = try ziac.gcp.secret_manager.SecretVersion.build(std.testing.allocator, provider, .{
        .name = "initial",
        .secret_id = "database-url",
        .source = .{ .provider = "config", .resource = "DATABASE_URL" },
    });
    defer version.deinit(std.testing.allocator);
    var member = try ziac.gcp.secret_manager.SecretIamMember.build(std.testing.allocator, provider, .{
        .name = "runtime-accessor",
        .secret_id = "database-url",
        .role = "roles/secretmanager.secretAccessor",
        .member = "serviceAccount:ziac-runtime@ziac-dev.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.secret.Secret.database-url", secret.node.id);
    try std.testing.expectEqualStrings("gcp.secret.SecretVersion.database-url.initial", version.node.id);
    try std.testing.expectEqualStrings("gcp.secret.SecretIamMember.database-url.runtime-accessor", member.node.id);
    try std.testing.expect(secret.resource_name == .resource_ref);
    try std.testing.expect(secret.node.lifecycle.retain_on_delete);
    try std.testing.expect(version.version == .resource_ref);
    try std.testing.expectEqual(ziac.output.Secrecy.secret, @TypeOf(version.version).secrecy);
    try std.testing.expect(member.binding_id == .resource_ref);

    const version_json = try version.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(version_json);
    try std.testing.expectEqualStrings(
        "{\"name\":\"initial\",\"project_id\":\"ziac-dev\",\"removal_policy\":\"retain\",\"secret_id\":\"database-url\",\"source\":{\"$secret\":{\"provider\":\"config\",\"resource\":\"DATABASE_URL\"}},\"state\":\"ENABLED\"}",
        version_json,
    );
    try std.testing.expect(std.mem.indexOf(u8, version_json, "sentinel-secret-for-tests") == null);
}

test "Secret Manager resources validate identifiers roles and members" {
    try std.testing.expectError(error.MissingName, ziac.gcp.secret_manager.Secret.build(std.testing.allocator, provider, .{ .name = "" }));
    try std.testing.expectError(error.MissingName, ziac.gcp.secret_manager.SecretVersion.build(std.testing.allocator, provider, .{
        .name = "",
        .secret_id = "database-url",
        .source = .{ .provider = "config", .resource = "DATABASE_URL" },
    }));
    try std.testing.expectError(error.InvalidRole, ziac.gcp.secret_manager.SecretIamMember.build(std.testing.allocator, provider, .{
        .name = "bad",
        .secret_id = "database-url",
        .role = "owner",
        .member = "user:owner@example.com",
    }));
    try std.testing.expectError(error.InvalidMember, ziac.gcp.secret_manager.SecretIamMember.build(std.testing.allocator, provider, .{
        .name = "bad",
        .secret_id = "database-url",
        .role = "roles/secretmanager.secretAccessor",
        .member = "owner@example.com",
    }));
}

test "Secret Manager declarations model replicated rotation and safe version state" {
    const replicas = [_]ziac.gcp.secret_manager.Replica{
        .{ .location = "europe-west1", .kms_key_name = "projects/ziac-dev/locations/europe-west1/keyRings/app/cryptoKeys/secrets" },
        .{ .location = "us-central1" },
    };
    const topics = [_][]const u8{"projects/ziac-dev/topics/secret-rotation"};
    const aliases = [_]ziac.gcp.secret_manager.VersionAlias{.{ .alias = "current", .version = 7 }};
    const annotations = [_]ziac.gcp.secret_manager.Annotation{.{ .key = "owner", .value = "platform" }};
    var secret = try ziac.gcp.secret_manager.Secret.build(std.testing.allocator, provider, .{
        .name = "replicated-database-url",
        .replication = .{ .user_managed = &replicas },
        .topics = &topics,
        .rotation = .{ .next_rotation_time = "2026-08-01T00:00:00Z", .period_seconds = 86_400 },
        .version_aliases = &aliases,
        .annotations = &annotations,
    });
    defer secret.deinit(std.testing.allocator);
    var version = try ziac.gcp.secret_manager.SecretVersion.build(std.testing.allocator, provider, .{
        .name = "initial",
        .secret_id = "replicated-database-url",
        .source = .{ .provider = "config", .resource = "DATABASE_URL" },
        .state = .disabled,
        .removal_policy = .retain,
    });
    defer version.deinit(std.testing.allocator);

    try std.testing.expect(version.node.lifecycle.retain_on_delete);
    const secret_json = try secret.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(secret_json);
    try std.testing.expect(std.mem.indexOf(u8, secret_json, "\"replication_mode\":\"user_managed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, secret_json, "\"rotation_period_seconds\":86400") != null);
    try std.testing.expect(std.mem.indexOf(u8, secret_json, "europe-west1") != null);
}

test "Secret Manager declarations reject unsafe replication and rotation" {
    const duplicate = [_]ziac.gcp.secret_manager.Replica{
        .{ .location = "europe-west1" },
        .{ .location = "europe-west1" },
    };
    try std.testing.expectError(error.InvalidReplication, ziac.gcp.secret_manager.Secret.build(std.testing.allocator, provider, .{
        .name = "duplicate",
        .replication = .{ .user_managed = &duplicate },
    }));
    try std.testing.expectError(error.InvalidRotation, ziac.gcp.secret_manager.Secret.build(std.testing.allocator, provider, .{
        .name = "rotation-without-topic",
        .rotation = .{ .next_rotation_time = "2026-08-01T00:00:00Z", .period_seconds = 3600 },
    }));
    try std.testing.expectError(error.InvalidReplication, ziac.gcp.secret_manager.Secret.build(std.testing.allocator, provider, .{
        .name = "automatic-regional-cmek",
        .replication = .{ .automatic = "projects/ziac-dev/locations/europe-west1/keyRings/app/cryptoKeys/secrets" },
    }));
}
