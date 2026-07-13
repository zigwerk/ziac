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

test "workspace revisions identify only changed project inputs" {
    const before = [_]ziac.workspace.ProjectRevision{
        .{ .id = "billing", .digest = [_]u8{1} ** 32 },
        .{ .id = "control-plane", .digest = [_]u8{2} ** 32 },
    };
    const after = [_]ziac.workspace.ProjectRevision{
        .{ .id = "billing", .digest = [_]u8{3} ** 32 },
        .{ .id = "control-plane", .digest = [_]u8{2} ** 32 },
    };
    const changed = try ziac.workspace.changedProjectsAlloc(std.testing.allocator, &before, &after);
    defer std.testing.allocator.free(changed);
    try std.testing.expectEqual(@as(usize, 1), changed.len);
    try std.testing.expectEqualStrings("billing", changed[0]);
}

test "workspace project revisions change only when declared inputs change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "not declared" });
    const manifest = projectManifest("api", "global-api");
    const first = try ziac.workspace.projectRevision(std.testing.allocator, std.testing.io, tmp.dir, manifest, &.{"src"});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "still not declared" });
    const unchanged = try ziac.workspace.projectRevision(std.testing.allocator, std.testing.io, tmp.dir, manifest, &.{"src"});
    try std.testing.expectEqualSlices(u8, &first, &unchanged);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void { @panic(\"changed\"); }" });
    const changed = try ziac.workspace.projectRevision(std.testing.allocator, std.testing.io, tmp.dir, manifest, &.{"src"});
    try std.testing.expect(!std.mem.eql(u8, &first, &changed));
}

test "workspace visual revisions and patches replace only changed project slices" {
    const before_projects = [_]ziac.workspace.ProjectVisualArtifact{
        .{ .id = "billing", .path = "platform/billing", .stack = "billing", .stage = "prod", .artifact_json = "{\"schema\":\"ziac.visual.v1\",\"resources\":[{\"id\":\"old\"}]}" },
        .{ .id = "control-plane", .path = "platform/control-plane", .stack = "control-plane", .stage = "prod", .artifact_json = "{\"schema\":\"ziac.visual.v1\",\"resources\":[]}" },
    };
    const after_projects = [_]ziac.workspace.ProjectVisualArtifact{
        .{ .id = "billing", .path = "platform/billing", .stack = "billing", .stage = "prod", .artifact_json = "{\"schema\":\"ziac.visual.v1\",\"resources\":[{\"id\":\"new\"}]}" },
        .{ .id = "control-plane", .path = "platform/control-plane", .stack = "control-plane", .stage = "prod", .artifact_json = "{\"schema\":\"ziac.visual.v1\",\"resources\":[]}" },
    };
    const before = try ziac.workspace.serializeVisualAlloc(std.testing.allocator, .{ .workspace = "ziac-cloud", .created_at_millis = 1, .projects = &before_projects });
    defer std.testing.allocator.free(before);
    const after = try ziac.workspace.serializeVisualAlloc(std.testing.allocator, .{ .workspace = "ziac-cloud", .created_at_millis = 2, .projects = &after_projects });
    defer std.testing.allocator.free(after);

    const patch = try ziac.workspace.patchAlloc(std.testing.allocator, before, after);
    defer std.testing.allocator.free(patch);
    var parsed_patch = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, patch, .{});
    defer parsed_patch.deinit();
    try std.testing.expectEqualStrings("ziac.workspace-patch.v1", parsed_patch.value.object.get("schema").?.string);
    try std.testing.expectEqual(@as(usize, 1), parsed_patch.value.object.get("changed_projects").?.array.items.len);
    try std.testing.expectEqualStrings("billing", parsed_patch.value.object.get("changed_projects").?.array.items[0].object.get("project").?.string);
    try std.testing.expectEqual(@as(usize, 0), parsed_patch.value.object.get("removed_project_ids").?.array.items.len);

    const applied = try ziac.workspace.applyPatchAlloc(std.testing.allocator, before, patch);
    defer std.testing.allocator.free(applied);
    try std.testing.expectEqualStrings(after, applied);
    try std.testing.expectError(error.StaleWorkspacePatch, ziac.workspace.applyPatchAlloc(std.testing.allocator, after, patch));
}

test "workspace patches report removed projects and deterministic no-op revisions" {
    const projects = [_]ziac.workspace.ProjectVisualArtifact{
        .{ .id = "api", .path = "platform/api", .stack = "api", .stage = "prod", .artifact_json = "{\"schema\":\"ziac.visual.v1\",\"resources\":[]}" },
        .{ .id = "worker", .path = "platform/worker", .stack = "worker", .stage = "prod", .artifact_json = "{\"schema\":\"ziac.visual.v1\",\"resources\":[]}" },
    };
    const remaining = [_]ziac.workspace.ProjectVisualArtifact{projects[0]};
    const first = try ziac.workspace.serializeVisualAlloc(std.testing.allocator, .{ .workspace = "ziac-cloud", .created_at_millis = 1, .projects = &projects });
    defer std.testing.allocator.free(first);
    const same = try ziac.workspace.serializeVisualAlloc(std.testing.allocator, .{ .workspace = "ziac-cloud", .created_at_millis = 999, .projects = &projects });
    defer std.testing.allocator.free(same);
    try std.testing.expectEqualStrings(ziac.workspace.revision(first).?, ziac.workspace.revision(same).?);
    const after = try ziac.workspace.serializeVisualAlloc(std.testing.allocator, .{ .workspace = "ziac-cloud", .created_at_millis = 2, .projects = &remaining });
    defer std.testing.allocator.free(after);
    const patch = try ziac.workspace.patchAlloc(std.testing.allocator, first, after);
    defer std.testing.allocator.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, "\"removed_project_ids\":[\"worker\"]") != null);
}

fn projectManifest(comptime id: []const u8, comptime stack: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "{{\"schema\":\"ziac.project.v1\",\"project\":\"{s}\",\"dashboard\":{{\"stack\":\"{s}\",\"stage\":\"dev\"}}}}",
        .{ id, stack },
    );
}
