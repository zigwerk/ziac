const std = @import("std");

pub const ProjectRevision = struct {
    id: []const u8,
    digest: [32]u8,
};

pub fn changedProjectsAlloc(
    allocator: std.mem.Allocator,
    before: []const ProjectRevision,
    after: []const ProjectRevision,
) ![][]const u8 {
    var changed = std.ArrayList([]const u8).empty;
    errdefer changed.deinit(allocator);
    for (after) |candidate| {
        var previous: ?[32]u8 = null;
        for (before) |entry| if (std.mem.eql(u8, entry.id, candidate.id)) {
            previous = entry.digest;
            break;
        };
        if (previous == null or !std.mem.eql(u8, &previous.?, &candidate.digest)) try changed.append(allocator, candidate.id);
    }
    return changed.toOwnedSlice(allocator);
}

pub fn projectRevision(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: std.Io.Dir,
    manifest: []const u8,
    source_roots: []const []const u8,
) ![32]u8 {
    var paths = std.ArrayList([]u8).empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    for (source_roots) |source_root| {
        if (!validSourceRoot(source_root)) return error.InvalidWorkspaceSourceRoot;
        const stat = project_dir.statFile(io, source_root, .{}) catch return error.WorkspaceSourceUnavailable;
        if (stat.kind == .file) {
            try paths.append(allocator, try allocator.dupe(u8, source_root));
            continue;
        }
        if (stat.kind != .directory) return error.WorkspaceSourceUnavailable;
        var source_dir = try project_dir.openDir(io, source_root, .{ .iterate = true });
        defer source_dir.close(io);
        var walker = try source_dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory and excludedDirectory(entry.basename)) {
                walker.leave(io);
                continue;
            }
            if (entry.kind != .file) continue;
            try paths.append(allocator, try std.fs.path.join(allocator, &.{ source_root, entry.path }));
        }
    }
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(manifest);
    for (paths.items) |path| {
        hasher.update(path);
        const bytes = try project_dir.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        hasher.update(bytes);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn validSourceRoot(path: []const u8) bool {
    return path.len > 0 and path.len <= 1024 and !std.fs.path.isAbsolute(path) and std.mem.indexOf(u8, path, "..") == null and std.mem.indexOfScalar(u8, path, 0) == null;
}

pub const schema = "ziac.workspace-visual.v1";
pub const format_version: u32 = 1;
pub const max_projects: usize = 256;
pub const max_manifest_bytes: usize = 4 * 1024 * 1024;
pub const max_depth: usize = 24;

pub const DiscoveredProject = struct {
    id: []const u8,
    path: []const u8,
    stack: []const u8,
    stage: []const u8,
};

pub const Discovery = struct {
    allocator: std.mem.Allocator,
    projects: []DiscoveredProject,

    pub fn deinit(self: *Discovery) void {
        for (self.projects) |project| {
            self.allocator.free(project.id);
            self.allocator.free(project.path);
            self.allocator.free(project.stack);
            self.allocator.free(project.stage);
        }
        self.allocator.free(self.projects);
        self.* = undefined;
    }
};

pub const ProjectVisualArtifact = struct {
    id: []const u8,
    path: []const u8,
    stack: []const u8,
    stage: []const u8,
    artifact_json: []const u8,
};

pub const VisualOptions = struct {
    workspace: []const u8,
    created_at_millis: u64,
    projects: []const ProjectVisualArtifact,
};

pub fn discoverProjectsAlloc(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !Discovery {
    var projects = std.ArrayList(DiscoveredProject).empty;
    errdefer deinitProjectList(allocator, &projects);

    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and (entry.depth() >= max_depth or excludedDirectory(entry.basename))) {
            walker.leave(io);
            continue;
        }
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "ziac.project.json")) continue;
        if (projects.items.len >= max_projects) return error.TooManyWorkspaceProjects;

        const manifest = root.readFileAlloc(io, entry.path, allocator, .limited(max_manifest_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.WorkspaceManifestTooLarge,
            else => return err,
        };
        defer allocator.free(manifest);
        try projects.append(allocator, try parseDiscoveredProjectAlloc(allocator, entry.path, manifest));
    }

    std.mem.sort(DiscoveredProject, projects.items, {}, lessThanProject);
    if (projects.items.len > 1) {
        for (projects.items[1..], projects.items[0 .. projects.items.len - 1]) |current, previous| {
            if (std.mem.eql(u8, current.id, previous.id)) return error.DuplicateWorkspaceProject;
        }
    }
    return .{ .allocator = allocator, .projects = try projects.toOwnedSlice(allocator) };
}

pub fn serializeVisualAlloc(allocator: std.mem.Allocator, options: VisualOptions) ![]u8 {
    try validateToken(options.workspace);
    if (options.projects.len == 0) return error.EmptyWorkspace;
    if (options.projects.len > max_projects) return error.TooManyWorkspaceProjects;

    var projects_json = std.ArrayList(u8).empty;
    defer projects_json.deinit(allocator);
    try projects_json.append(allocator, '[');
    for (options.projects, 0..) |project, index| {
        try validateToken(project.id);
        try validateRelativePath(project.path);
        try validateToken(project.stack);
        try validateToken(project.stage);
        try validateVisualArtifact(allocator, project.artifact_json);
        if (index != 0) try projects_json.append(allocator, ',');
        try projects_json.appendSlice(allocator, "{\"project\":");
        try appendJsonString(&projects_json, allocator, project.id);
        try projects_json.appendSlice(allocator, ",\"path\":");
        try appendJsonString(&projects_json, allocator, project.path);
        try projects_json.appendSlice(allocator, ",\"stack\":");
        try appendJsonString(&projects_json, allocator, project.stack);
        try projects_json.appendSlice(allocator, ",\"stage\":");
        try appendJsonString(&projects_json, allocator, project.stage);
        try projects_json.appendSlice(allocator, ",\"artifact\":");
        try projects_json.appendSlice(allocator, project.artifact_json);
        try projects_json.append(allocator, '}');
    }
    try projects_json.append(allocator, ']');
    const revision_hex = workspaceRevisionHex(options.workspace, projects_json.items);
    return emitWorkspaceAlloc(allocator, options.workspace, options.created_at_millis, &revision_hex, projects_json.items, "[]");
}

pub fn revision(bytes: []const u8) ?[]const u8 {
    const marker = "\"revision\":\"";
    const start = (std.mem.indexOf(u8, bytes, marker) orelse return null) + marker.len;
    if (start + 64 > bytes.len or bytes[start + 64] != '"') return null;
    const value = bytes[start .. start + 64];
    for (value) |byte| if (!(std.ascii.isDigit(byte) or byte >= 'a' and byte <= 'f')) return null;
    return value;
}

pub fn patchAlloc(allocator: std.mem.Allocator, before_bytes: []const u8, after_bytes: []const u8) ![]u8 {
    var before = std.json.parseFromSlice(std.json.Value, allocator, before_bytes, .{}) catch return error.InvalidWorkspaceArtifact;
    defer before.deinit();
    var after = std.json.parseFromSlice(std.json.Value, allocator, after_bytes, .{}) catch return error.InvalidWorkspaceArtifact;
    defer after.deinit();
    const before_root = try workspaceRoot(before.value);
    const after_root = try workspaceRoot(after.value);
    const base_revision = revision(before_bytes) orelse return error.InvalidWorkspaceArtifact;
    const next_revision = revision(after_bytes) orelse return error.InvalidWorkspaceArtifact;
    const after_projects = try workspaceProjects(after_root);
    const before_projects = try workspaceProjects(before_root);
    const workspace_name = jsonString(after_root.get("workspace")) orelse return error.InvalidWorkspaceArtifact;
    const created_at = jsonInteger(after_root.get("created_at_millis")) orelse return error.InvalidWorkspaceArtifact;
    const links = after_root.get("links") orelse return error.InvalidWorkspaceArtifact;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"schema\":\"ziac.workspace-patch.v1\",\"base_revision\":");
    try appendJsonString(&output, allocator, base_revision);
    try output.appendSlice(allocator, ",\"revision\":");
    try appendJsonString(&output, allocator, next_revision);
    try output.appendSlice(allocator, ",\"workspace\":");
    try appendJsonString(&output, allocator, workspace_name);
    try output.print(allocator, ",\"created_at_millis\":{d},\"changed_projects\":[", .{created_at});
    var changed_count: usize = 0;
    for (after_projects.items) |project| {
        const id = try visualProjectId(project);
        const previous = findVisualProject(before_projects.items, id);
        if (previous != null and try jsonValuesEqual(allocator, previous.?, project)) continue;
        if (changed_count != 0) try output.append(allocator, ',');
        try appendJsonValue(&output, allocator, project);
        changed_count += 1;
    }
    try output.appendSlice(allocator, "],\"removed_project_ids\":[");
    var removed_count: usize = 0;
    for (before_projects.items) |project| {
        const id = try visualProjectId(project);
        if (findVisualProject(after_projects.items, id) != null) continue;
        if (removed_count != 0) try output.append(allocator, ',');
        try appendJsonString(&output, allocator, id);
        removed_count += 1;
    }
    try output.appendSlice(allocator, "],\"project_order\":[");
    for (after_projects.items, 0..) |project, index| {
        if (index != 0) try output.append(allocator, ',');
        try appendJsonString(&output, allocator, try visualProjectId(project));
    }
    try output.appendSlice(allocator, "],\"links\":");
    try appendJsonValue(&output, allocator, links);
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

pub fn applyPatchAlloc(allocator: std.mem.Allocator, current_bytes: []const u8, patch_bytes: []const u8) ![]u8 {
    const current_revision = revision(current_bytes) orelse return error.InvalidWorkspaceArtifact;
    var current = std.json.parseFromSlice(std.json.Value, allocator, current_bytes, .{}) catch return error.InvalidWorkspaceArtifact;
    defer current.deinit();
    var patch = std.json.parseFromSlice(std.json.Value, allocator, patch_bytes, .{}) catch return error.InvalidWorkspacePatch;
    defer patch.deinit();
    const current_root = try workspaceRoot(current.value);
    if (patch.value != .object) return error.InvalidWorkspacePatch;
    const patch_root = patch.value.object;
    if (!std.mem.eql(u8, jsonString(patch_root.get("schema")) orelse return error.InvalidWorkspacePatch, "ziac.workspace-patch.v1")) return error.InvalidWorkspacePatch;
    const base_revision = jsonString(patch_root.get("base_revision")) orelse return error.InvalidWorkspacePatch;
    if (!std.mem.eql(u8, current_revision, base_revision)) return error.StaleWorkspacePatch;
    const next_revision = jsonString(patch_root.get("revision")) orelse return error.InvalidWorkspacePatch;
    const workspace_name = jsonString(patch_root.get("workspace")) orelse return error.InvalidWorkspacePatch;
    const created_at = jsonInteger(patch_root.get("created_at_millis")) orelse return error.InvalidWorkspacePatch;
    const changed = jsonArray(patch_root.get("changed_projects")) orelse return error.InvalidWorkspacePatch;
    const order = jsonArray(patch_root.get("project_order")) orelse return error.InvalidWorkspacePatch;
    const links = patch_root.get("links") orelse return error.InvalidWorkspacePatch;
    const current_projects = try workspaceProjects(current_root);

    var projects_json = std.ArrayList(u8).empty;
    defer projects_json.deinit(allocator);
    try projects_json.append(allocator, '[');
    for (order.items, 0..) |id_value, index| {
        if (id_value != .string) return error.InvalidWorkspacePatch;
        const selected = findVisualProject(changed.items, id_value.string) orelse findVisualProject(current_projects.items, id_value.string) orelse return error.InvalidWorkspacePatch;
        if (index != 0) try projects_json.append(allocator, ',');
        try appendJsonValue(&projects_json, allocator, selected);
    }
    try projects_json.append(allocator, ']');
    const computed_revision = workspaceRevisionHex(workspace_name, projects_json.items);
    if (!std.mem.eql(u8, &computed_revision, next_revision)) return error.InvalidWorkspacePatch;
    const links_json = try std.json.Stringify.valueAlloc(allocator, links, .{});
    defer allocator.free(links_json);
    return emitWorkspaceAlloc(allocator, workspace_name, created_at, &computed_revision, projects_json.items, links_json);
}

fn emitWorkspaceAlloc(
    allocator: std.mem.Allocator,
    workspace_name: []const u8,
    created_at_millis: u64,
    revision_hex: []const u8,
    projects_json: []const u8,
    links_json: []const u8,
) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"schema\":\"");
    try output.appendSlice(allocator, schema);
    try output.appendSlice(allocator, "\",\"format_version\":1,\"workspace\":");
    try appendJsonString(&output, allocator, workspace_name);
    try output.print(allocator, ",\"created_at_millis\":{d},\"revision\":", .{created_at_millis});
    try appendJsonString(&output, allocator, revision_hex);
    try output.appendSlice(allocator, ",\"projects\":");
    try output.appendSlice(allocator, projects_json);
    try output.appendSlice(allocator, ",\"links\":");
    try output.appendSlice(allocator, links_json);
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

fn workspaceRevisionHex(workspace_name: []const u8, projects_json: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(workspace_name);
    hasher.update("\x00");
    hasher.update(projects_json);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn workspaceRoot(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidWorkspaceArtifact;
    if (!std.mem.eql(u8, jsonString(value.object.get("schema")) orelse return error.InvalidWorkspaceArtifact, schema)) return error.InvalidWorkspaceArtifact;
    return value.object;
}

fn workspaceProjects(root: std.json.ObjectMap) !std.json.Array {
    return jsonArray(root.get("projects")) orelse error.InvalidWorkspaceArtifact;
}

fn visualProjectId(value: std.json.Value) ![]const u8 {
    if (value != .object) return error.InvalidWorkspaceArtifact;
    return jsonString(value.object.get("project")) orelse error.InvalidWorkspaceArtifact;
}

fn findVisualProject(projects: []const std.json.Value, id: []const u8) ?std.json.Value {
    for (projects) |project| {
        const candidate = visualProjectId(project) catch continue;
        if (std.mem.eql(u8, candidate, id)) return project;
    }
    return null;
}

fn jsonValuesEqual(allocator: std.mem.Allocator, left: std.json.Value, right: std.json.Value) !bool {
    const left_bytes = try std.json.Stringify.valueAlloc(allocator, left, .{});
    defer allocator.free(left_bytes);
    const right_bytes = try std.json.Stringify.valueAlloc(allocator, right, .{});
    defer allocator.free(right_bytes);
    return std.mem.eql(u8, left_bytes, right_bytes);
}

fn appendJsonValue(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: std.json.Value) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try output.appendSlice(allocator, encoded);
}

fn parseDiscoveredProjectAlloc(allocator: std.mem.Allocator, manifest_path: []const u8, bytes: []const u8) !DiscoveredProject {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidWorkspaceProject;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidWorkspaceProject;
    const root = parsed.value.object;
    const manifest_schema = jsonString(root.get("schema")) orelse return error.InvalidWorkspaceProject;
    if (!std.mem.eql(u8, manifest_schema, "ziac.project.v1")) return error.InvalidWorkspaceProject;
    const id = jsonString(root.get("project")) orelse return error.InvalidWorkspaceProject;
    try validateToken(id);

    var stack: []const u8 = "global-api";
    var stage: []const u8 = "dev";
    if (root.get("dashboard")) |dashboard_value| {
        if (dashboard_value != .object) return error.InvalidWorkspaceProject;
        stack = jsonString(dashboard_value.object.get("stack")) orelse return error.InvalidWorkspaceProject;
        stage = jsonString(dashboard_value.object.get("stage")) orelse return error.InvalidWorkspaceProject;
    }
    try validateToken(stack);
    try validateToken(stage);
    const dirname = std.fs.path.dirname(manifest_path) orelse ".";
    try validateRelativePath(dirname);

    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_path = try normalizePathAlloc(allocator, dirname);
    errdefer allocator.free(owned_path);
    const owned_stack = try allocator.dupe(u8, stack);
    errdefer allocator.free(owned_stack);
    const owned_stage = try allocator.dupe(u8, stage);
    return .{ .id = owned_id, .path = owned_path, .stack = owned_stack, .stage = owned_stage };
}

fn validateVisualArtifact(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidWorkspaceVisualArtifact;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidWorkspaceVisualArtifact;
    const child_schema = jsonString(parsed.value.object.get("schema")) orelse return error.InvalidWorkspaceVisualArtifact;
    if (!std.mem.eql(u8, child_schema, "ziac.visual.v1")) return error.InvalidWorkspaceVisualArtifact;
}

fn appendJsonString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try output.appendSlice(allocator, encoded);
}

fn validateToken(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidWorkspaceToken;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') {
        return error.InvalidWorkspaceToken;
    };
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) {
        return error.InvalidWorkspacePath;
    }
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidWorkspacePath;
}

fn normalizePathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, path);
    for (result) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
    return result;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return if (present == .string) present.string else null;
}

fn jsonInteger(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn jsonArray(value: ?std.json.Value) ?std.json.Array {
    const present = value orelse return null;
    return if (present == .array) present.array else null;
}

fn excludedDirectory(name: []const u8) bool {
    const excluded = [_][]const u8{
        ".git", ".ziac", ".zig-cache", "zig-cache", "zig-out", "node_modules", "vendor", "fixtures", ".cache",
    };
    for (excluded) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn lessThanProject(_: void, left: DiscoveredProject, right: DiscoveredProject) bool {
    const order = std.mem.order(u8, left.id, right.id);
    return order == .lt or (order == .eq and std.mem.lessThan(u8, left.path, right.path));
}

fn deinitProjectList(allocator: std.mem.Allocator, projects: *std.ArrayList(DiscoveredProject)) void {
    for (projects.items) |project| {
        allocator.free(project.id);
        allocator.free(project.path);
        allocator.free(project.stack);
        allocator.free(project.stage);
    }
    projects.deinit(allocator);
}
