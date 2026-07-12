const std = @import("std");
const ziac = @import("ziac");

test "workspace discovery finds nested projects deterministically and ignores generated trees" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "services/payments/infra");
    try tmp.dir.createDirPath(std.testing.io, "platform");
    try tmp.dir.createDirPath(std.testing.io, "node_modules/ignored");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "services/payments/infra/ziac.project.json",
        .data = projectManifest("payments", "payments-api"),
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "platform/ziac.project.json",
        .data = projectManifest("platform", "foundation"),
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "node_modules/ignored/ziac.project.json",
        .data = projectManifest("ignored", "ignored"),
    });

    var discovered = try ziac.workspace.discoverProjectsAlloc(std.testing.allocator, std.testing.io, tmp.dir);
    defer discovered.deinit();

    try std.testing.expectEqual(@as(usize, 2), discovered.projects.len);
    try std.testing.expectEqualStrings("payments", discovered.projects[0].id);
    try std.testing.expectEqualStrings("services/payments/infra", discovered.projects[0].path);
    try std.testing.expectEqualStrings("payments-api", discovered.projects[0].stack);
    try std.testing.expectEqualStrings("platform", discovered.projects[1].id);
    try std.testing.expectEqualStrings("foundation", discovered.projects[1].stack);
    try std.testing.expectEqualStrings("dev", discovered.projects[1].stage);
}

test "workspace discovery rejects duplicate stable project identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "one");
    try tmp.dir.createDirPath(std.testing.io, "two");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "one/ziac.project.json", .data = projectManifest("api", "one") });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "two/ziac.project.json", .data = projectManifest("api", "two") });

    try std.testing.expectError(
        error.DuplicateWorkspaceProject,
        ziac.workspace.discoverProjectsAlloc(std.testing.allocator, std.testing.io, tmp.dir),
    );
}

test "workspace visual artifact preserves project boundaries and embeds child artifacts" {
    const projects = [_]ziac.workspace.ProjectVisualArtifact{
        .{
            .id = "payments",
            .path = "services/payments/infra",
            .stack = "payments-api",
            .stage = "dev",
            .artifact_json = "{\"schema\":\"ziac.visual.v1\",\"resources\":[]}",
        },
        .{
            .id = "platform",
            .path = "platform",
            .stack = "foundation",
            .stage = "dev",
            .artifact_json = "{\"schema\":\"ziac.visual.v1\",\"resources\":[]}",
        },
    };
    const artifact = try ziac.workspace.serializeVisualAlloc(std.testing.allocator, .{
        .workspace = "ziac-cloud",
        .created_at_millis = 42,
        .projects = &projects,
    });
    defer std.testing.allocator.free(artifact);

    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"schema\":\"ziac.workspace-visual.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"project\":\"payments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"path\":\"platform\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"artifact\":{\"schema\":\"ziac.visual.v1\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, artifact, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ziac.workspace-visual.v1", parsed.value.object.get("schema").?.string);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("projects").?.array.items.len);
}

fn projectManifest(comptime id: []const u8, comptime stack: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "{{\"schema\":\"ziac.project.v1\",\"project\":\"{s}\",\"dashboard\":{{\"stack\":\"{s}\",\"stage\":\"dev\"}}}}",
        .{ id, stack },
    );
}
