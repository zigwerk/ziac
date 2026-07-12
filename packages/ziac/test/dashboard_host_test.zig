const std = @import("std");
const ziac = @import("ziac");

test "dashboard host requires an explicit artifact and owns Ziac bridge names" {
    const args = [_][:0]const u8{
        "ziac-dashboard-host",
        "--server-only",
        "--root",
        "dashboard/dist",
        "--session",
        ".ziac/dashboard/session.json",
        "--logs",
        ".ziac/logs/events.jsonl",
        ".ziac/dashboard/artifact.json",
    };
    const options = ziac.dashboard_host.parseLaunchArgs(&args).?;
    try std.testing.expectEqual(ziac.dashboard_host.LaunchMode.server_only, options.mode);
    try std.testing.expectEqualStrings("dashboard/dist", options.root_path);
    try std.testing.expectEqualStrings(".ziac/dashboard/artifact.json", options.artifact_path);
    try std.testing.expectEqualStrings(".ziac/dashboard/session.json", options.session_path.?);
    try std.testing.expectEqualStrings(".ziac/logs/events.jsonl", options.log_path.?);
    try std.testing.expectEqualStrings("ziac_load_artifact", ziac.dashboard_host.bridge_names.load_artifact);
    try std.testing.expect(ziac.dashboard_host.parseLaunchArgs(&.{"ziac-dashboard-host"}) == null);
}

test "dashboard host reads bounded live files and generates an honest session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const artifact = "{\"schema\":\"ziac.visual.v1\",\"resources\":[]}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "artifact.json", .data = artifact });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "events.jsonl", .data = "{\"schema\":\"ziac.log.v1\"}\n" });
    var host = ziac.dashboard_host.Host.init(std.testing.allocator, std.testing.io, tmp.dir, .{
        .artifact_path = "artifact.json",
        .log_path = "events.jsonl",
    });
    const loaded = try host.loadArtifactAlloc();
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualStrings(artifact, loaded);
    const session = try host.loadSessionAlloc();
    defer std.testing.allocator.free(session);
    try std.testing.expect(std.mem.indexOf(u8, session, "\"schema\":\"ziac.dashboard-session.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, session, "\"fixture\"") == null);
    const logs = try host.loadLogAlloc();
    defer std.testing.allocator.free(logs);
    try std.testing.expect(std.mem.indexOf(u8, logs, "ziac.log.v1") != null);
}

test "dashboard host fails closed for missing and oversized artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var missing = ziac.dashboard_host.Host.init(std.testing.allocator, std.testing.io, tmp.dir, .{ .artifact_path = "missing.json" });
    try std.testing.expectError(error.DashboardArtifactUnavailable, missing.loadArtifactAlloc());

    const oversized = try std.testing.allocator.alloc(u8, ziac.dashboard_host.max_artifact_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "large.json", .data = oversized });
    var host = ziac.dashboard_host.Host.init(std.testing.allocator, std.testing.io, tmp.dir, .{ .artifact_path = "large.json" });
    try std.testing.expectError(error.DashboardArtifactTooLarge, host.loadArtifactAlloc());
}
