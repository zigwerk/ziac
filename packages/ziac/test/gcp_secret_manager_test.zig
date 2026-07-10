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
    try std.testing.expect(version.version == .resource_ref);
    try std.testing.expectEqual(ziac.output.Secrecy.secret, @TypeOf(version.version).secrecy);
    try std.testing.expect(member.binding_id == .resource_ref);

    const version_json = try version.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(version_json);
    try std.testing.expectEqualStrings(
        "{\"name\":\"initial\",\"project_id\":\"ziac-dev\",\"secret_id\":\"database-url\",\"source\":{\"$secret\":{\"provider\":\"config\",\"resource\":\"DATABASE_URL\"}}}",
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
