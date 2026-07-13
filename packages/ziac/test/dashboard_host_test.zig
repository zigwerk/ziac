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
    try std.testing.expectEqualStrings("ziac_operation_watch", ziac.dashboard_host.bridge_names.operation_watch);
    try std.testing.expectEqualStrings("ziac_operation_status", ziac.dashboard_host.bridge_names.operation_status);
    try std.testing.expectEqualStrings("ziac_operation_cancel", ziac.dashboard_host.bridge_names.operation_cancel);
    try std.testing.expect(ziac.dashboard_host.parseLaunchArgs(&.{"ziac-dashboard-host"}) == null);
}

test "dashboard host supervises a watch child and returns terminal status by operation id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "platform");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "platform/ziac.project.json",
        .data = "{\"schema\":\"ziac.project.v1\",\"project\":\"api\",\"dashboard\":{\"stack\":\"api\",\"stage\":\"prod\"}}",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "artifact.json", .data = "{\"schema\":\"ziac.visual.v1\"}" });
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    var host = ziac.dashboard_host.Host.init(std.testing.allocator, std.testing.io, tmp.dir, .{
        .artifact_path = "artifact.json",
        .refresh_executable = "/usr/bin/true",
        .refresh_root = root_path,
        .refresh_out = "artifact.json",
    });
    defer host.deinit();
    const started = try host.startWatchAlloc(
        "{\"schema\":\"ziac.dashboard-operation-request.v1\",\"operation\":\"watch\",\"project\":\"api\",\"stack\":\"api\",\"stage\":\"prod\",\"provider\":\"fake\",\"plan_digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}",
    );
    defer std.testing.allocator.free(started);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, started, .{});
    defer parsed.deinit();
    const operation_id = parsed.value.object.get("operation_id").?.string;
    const control = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema\":\"ziac.dashboard-operation-control.v1\",\"operation_id\":\"{s}\"}}", .{operation_id});
    defer std.testing.allocator.free(control);
    var terminal: ?[]u8 = null;
    defer if (terminal) |value| std.testing.allocator.free(value);
    for (0..10_000) |_| {
        const status = try host.operationStatusAlloc(control);
        if (std.mem.indexOf(u8, status, "\"phase\":\"succeeded\"") != null) {
            terminal = status;
            break;
        }
        std.testing.allocator.free(status);
        std.Thread.yield() catch {};
    }
    try std.testing.expect(terminal != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.?, "\"exit_code\":0") != null);
}

test "dashboard host source revision follows declared project inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "platform/src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "platform/ziac.project.json",
        .data =
        \\{"schema":"ziac.project.v1","project":"api","source_roots":["src"],"components":[],"requirements":[],"acceptance_checks":[],"environments":[],"adaptations":[],"scenarios":[],"dashboard":{"stack":"api","stage":"dev"},"authority":{"read":true,"plan":true,"apply":false,"delete":false,"secret_read":false,"live_network":false}}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "platform/src/main.zig", .data = "pub fn main() void {}" });
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    var host = ziac.dashboard_host.Host.init(std.testing.allocator, std.testing.io, tmp.dir, .{
        .artifact_path = "artifact.json",
        .refresh_root = root_path,
    });
    defer host.deinit();
    const first = try host.workspaceSourceRevision();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "platform/src/main.zig", .data = "pub fn main() void { @panic(\"changed\"); }" });
    const second = try host.workspaceSourceRevision();
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
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

test "dashboard host accepts one bounded workspace refresh command" {
    const args = [_][:0]const u8{
        "ziac-dashboard-host",
        "--server-only",
        "--workspace-refresh",
        "/opt/ziac/bin/ziac",
        "/repo/ziac-cloud",
        ".ziac/dashboard/workspace/artifact.json",
        "--project",
        "payments",
        "/repo/ziac-cloud/.ziac/dashboard/workspace/artifact.json",
    };
    const options = ziac.dashboard_host.parseLaunchArgs(&args).?;
    try std.testing.expectEqualStrings("/opt/ziac/bin/ziac", options.refresh_executable.?);
    try std.testing.expectEqualStrings("/repo/ziac-cloud", options.refresh_root.?);
    try std.testing.expectEqualStrings("payments", options.refresh_project.?);
}
