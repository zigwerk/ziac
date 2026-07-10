const std = @import("std");
const ziac = @import("ziac");

test "Cockroach SQL user binds a Secret Manager version without plaintext state" {
    const secret = ziac.SecretOutput(ziac.value.SecretReference).fromResource(
        "gcp.secret.SecretVersion.database-url.initial",
        "version",
    );
    var user = try ziac.cockroach.sql_user.SqlUser.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .username = "app_user",
        .connection_secret = secret,
    });
    defer user.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("cockroach.SqlUser.cluster-1.app_user", user.node.id);
    try std.testing.expectEqual(ziac.resource.ProviderId.cockroach, user.node.provider);
    try std.testing.expect(user.username == .resource_ref);
    const json = try user.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"cluster_id\":\"cluster-1\",\"connection_secret\":{\"$output\":{\"field\":\"version\",\"resource\":\"gcp.secret.SecretVersion.database-url.initial\"}},\"username\":\"app_user\"}",
        json,
    );
    try std.testing.expect(std.mem.indexOf(u8, json, "password") == null);
}

test "Cockroach SQL user validates usernames and secret readiness" {
    try std.testing.expectError(error.InvalidUsername, ziac.cockroach.sql_user.SqlUser.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .username = "App User",
        .connection_secret = ziac.SecretOutput(ziac.value.SecretReference).known(.{
            .provider = "gcp-secret-manager",
            .resource = "projects/p/secrets/database-url",
            .version = "1",
        }),
    }));
    try std.testing.expectError(error.SecretNotKnown, ziac.cockroach.sql_user.SqlUser.build(std.testing.allocator, .{}, .{
        .cluster_id = "cluster-1",
        .username = "app_user",
        .connection_secret = ziac.SecretOutput(ziac.value.SecretReference).unknown("pending"),
    }));
}
