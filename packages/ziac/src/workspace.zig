const std = @import("std");

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

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"schema\":\"");
    try output.appendSlice(allocator, schema);
    try output.appendSlice(allocator, "\",\"format_version\":1,\"workspace\":");
    try appendJsonString(&output, allocator, options.workspace);
    try output.print(allocator, ",\"created_at_millis\":{d},\"projects\":[", .{options.created_at_millis});
    for (options.projects, 0..) |project, index| {
        try validateToken(project.id);
        try validateRelativePath(project.path);
        try validateToken(project.stack);
        try validateToken(project.stage);
        try validateVisualArtifact(allocator, project.artifact_json);
        if (index != 0) try output.append(allocator, ',');
        try output.appendSlice(allocator, "{\"project\":");
        try appendJsonString(&output, allocator, project.id);
        try output.appendSlice(allocator, ",\"path\":");
        try appendJsonString(&output, allocator, project.path);
        try output.appendSlice(allocator, ",\"stack\":");
        try appendJsonString(&output, allocator, project.stack);
        try output.appendSlice(allocator, ",\"stage\":");
        try appendJsonString(&output, allocator, project.stage);
        try output.appendSlice(allocator, ",\"artifact\":");
        try output.appendSlice(allocator, project.artifact_json);
        try output.append(allocator, '}');
    }
    try output.appendSlice(allocator, "],\"links\":[]}");
    return output.toOwnedSlice(allocator);
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
