const std = @import("std");
const ziac = @import("ziac");

test "ephemeral leases are repository bound budgeted and expire closed" {
    var lease = try ziac.lease.Lease.init(std.testing.allocator, .{
        .id = "lease-42",
        .owner = "agent-session-42",
        .repository = "Acme/Platform",
        .change_number = 42,
        .created_at_millis = 1000,
        .expires_at_millis = 5000,
        .project = "project-dev",
        .state_prefix = "ziac/state/previews",
        .max_resources = 8,
        .max_monthly_cost_minor = 5000,
    });
    defer lease.deinit();
    try std.testing.expect(std.mem.startsWith(u8, lease.stage, "pr-42-"));
    try lease.authorizeMutation(4999, 4, 4000);
    try std.testing.expectError(error.LeaseExpired, lease.authorizeMutation(5000, 1, 1));
    try std.testing.expectError(error.LeaseExpired, lease.heartbeat(5000));

    const artifact = try lease.jsonAlloc(std.testing.allocator, 5000);
    defer std.testing.allocator.free(artifact);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "ziac.ephemeral-lease.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "expired") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "project-dev") != null);
}

test "expired preview cleanup is idempotent and production proof" {
    var lease = try ziac.lease.Lease.init(std.testing.allocator, .{
        .id = "lease-cleanup",
        .owner = "agent",
        .repository = "Acme/Platform",
        .change_number = 7,
        .created_at_millis = 1,
        .expires_at_millis = 10,
        .project = "project-dev",
        .state_prefix = "ziac/state/previews",
        .max_resources = 4,
        .max_monthly_cost_minor = 1000,
    });
    defer lease.deinit();
    var provider = ziac.lease.ScriptedCleanup.init(std.testing.allocator);
    defer provider.deinit();
    const resources = [_][]const u8{ "gcp.run.Service.pr", "cockroach.Cluster.pr" };
    const first = try lease.cleanup(provider.provider(), 11, &resources);
    try std.testing.expectEqual(@as(usize, 2), first.deleted);
    const second = try lease.cleanup(provider.provider(), 12, &resources);
    try std.testing.expectEqual(@as(usize, 0), second.deleted);
    try std.testing.expectEqual(@as(usize, 2), provider.delete_count);
    try std.testing.expectEqual(ziac.lease.Status.clean, lease.status);
}
