const std = @import("std");
const zstd = @import("zigeffect_std");
const stack_registry = @import("stack_registry.zig");
const state_mod = @import("state.zig");

pub const StateFileError = error{
    InvalidStateFile,
    MissingStateFile,
    UnknownStatus,
};

pub const FileStore = struct {
    ptr: *anyopaque,
    readFileAllocFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8,
    writeFileFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    existsFn: *const fn (*anyopaque, []const u8) anyerror!bool,

    pub fn readFileAlloc(
        self: FileStore,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) anyerror![]const u8 {
        return self.readFileAllocFn(self.ptr, allocator, path);
    }

    pub fn writeFile(self: FileStore, path: []const u8, content: []const u8) anyerror!void {
        try self.writeFileFn(self.ptr, path, content);
    }

    pub fn exists(self: FileStore, path: []const u8) anyerror!bool {
        return self.existsFn(self.ptr, path);
    }
};

pub fn memoryFiles(fs: *zstd.FileSystem.MemoryFileSystem) FileStore {
    return .{
        .ptr = fs,
        .readFileAllocFn = memoryReadFileAlloc,
        .writeFileFn = memoryWriteFile,
        .existsFn = memoryExists,
    };
}

fn memoryReadFileAlloc(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    path: []const u8,
) anyerror![]const u8 {
    const fs: *zstd.FileSystem.MemoryFileSystem = @ptrCast(@alignCast(raw));
    return fs.readFileAlloc(allocator, path);
}

fn memoryWriteFile(raw: *anyopaque, path: []const u8, content: []const u8) anyerror!void {
    const fs: *zstd.FileSystem.MemoryFileSystem = @ptrCast(@alignCast(raw));
    try fs.writeFile(path, content);
}

fn memoryExists(raw: *anyopaque, path: []const u8) anyerror!bool {
    const fs: *zstd.FileSystem.MemoryFileSystem = @ptrCast(@alignCast(raw));
    return fs.exists(path);
}

pub const localFiles = struct {
    pub fn store(fs: *zstd.FileSystem.LocalFileSystem) FileStore {
        return .{
            .ptr = fs,
            .readFileAllocFn = localReadFileAlloc,
            .writeFileFn = localWriteFile,
            .existsFn = localExists,
        };
    }

    fn localReadFileAlloc(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) anyerror![]const u8 {
        const fs: *zstd.FileSystem.LocalFileSystem = @ptrCast(@alignCast(raw));
        return fs.readFileAlloc(allocator, path);
    }

    fn localWriteFile(raw: *anyopaque, path: []const u8, content: []const u8) anyerror!void {
        const fs: *zstd.FileSystem.LocalFileSystem = @ptrCast(@alignCast(raw));
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            try fs.dir.createDirPath(fs.io, path[0..slash]);
        }
        try fs.writeFile(path, content);
    }

    fn localExists(raw: *anyopaque, path: []const u8) anyerror!bool {
        const fs: *zstd.FileSystem.LocalFileSystem = @ptrCast(@alignCast(raw));
        return fs.exists(path);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    files: FileStore,

    pub fn init(allocator: std.mem.Allocator, files: FileStore) Store {
        return .{
            .allocator = allocator,
            .files = files,
        };
    }

    pub fn resourcesPathAlloc(self: Store, stack: []const u8, stage: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, ".ziac/state/{s}/{s}/resources.json", .{ stack, stage });
    }

    pub fn outputsPathAlloc(self: Store, stack: []const u8, stage: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, ".ziac/state/{s}/{s}/outputs.json", .{ stack, stage });
    }

    pub fn saveResources(
        self: Store,
        stack: []const u8,
        stage: []const u8,
        state_store: *state_mod.InMemoryStateStore,
    ) !void {
        const path = try self.resourcesPathAlloc(stack, stage);
        defer self.allocator.free(path);

        const content = try resourcesJsonAlloc(self.allocator, state_store);
        defer self.allocator.free(content);

        try self.files.writeFile(path, content);
    }

    pub fn loadResources(self: Store, stack: []const u8, stage: []const u8) !LoadedResources {
        const path = try self.resourcesPathAlloc(stack, stage);
        defer self.allocator.free(path);

        const content = self.files.readFileAlloc(self.allocator, path) catch |err| switch (err) {
            error.FileNotFound => return error.MissingStateFile,
            else => return err,
        };
        defer self.allocator.free(content);

        return parseResources(self.allocator, content);
    }

    pub fn loadResourcesOrEmpty(self: Store, stack: []const u8, stage: []const u8) !LoadedResources {
        return self.loadResources(stack, stage) catch |err| switch (err) {
            error.MissingStateFile => emptyResources(self.allocator),
            else => return err,
        };
    }

    pub fn saveOutputs(
        self: Store,
        stack: []const u8,
        stage: []const u8,
        outputs: []const stack_registry.OutputEntry,
    ) !void {
        const path = try self.outputsPathAlloc(stack, stage);
        defer self.allocator.free(path);

        const content = try outputsJsonAlloc(self.allocator, outputs);
        defer self.allocator.free(content);

        try self.files.writeFile(path, content);
    }

    pub fn loadOutputs(self: Store, stack: []const u8, stage: []const u8) !LoadedOutputs {
        const path = try self.outputsPathAlloc(stack, stage);
        defer self.allocator.free(path);

        const content = self.files.readFileAlloc(self.allocator, path) catch |err| switch (err) {
            error.FileNotFound => return error.MissingStateFile,
            else => return err,
        };
        defer self.allocator.free(content);

        return parseOutputs(self.allocator, content);
    }
};

pub const LoadedResources = struct {
    arena: std.heap.ArenaAllocator,
    store: state_mod.InMemoryStateStore,

    pub fn deinit(self: *LoadedResources) void {
        self.store.deinit();
        self.arena.deinit();
    }
};

pub const OutputRecord = struct {
    name: []const u8,
    value: []const u8,
    secret: bool,
};

pub const LoadedOutputs = struct {
    arena: std.heap.ArenaAllocator,
    items: []OutputRecord,

    pub fn deinit(self: *LoadedOutputs) void {
        self.arena.deinit();
    }
};

fn emptyResources(allocator: std.mem.Allocator) !LoadedResources {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    return .{
        .arena = arena,
        .store = state_mod.InMemoryStateStore.init(allocator),
    };
}

fn resourcesJsonAlloc(
    allocator: std.mem.Allocator,
    state_store: *state_mod.InMemoryStateStore,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    const records = try state_store.recordsAlloc(allocator);
    defer allocator.free(records);

    try output.appendSlice(allocator, "{\"resources\":[");
    for (records, 0..) |record, index| {
        if (index != 0) try output.append(allocator, ',');
        try appendRecordJson(&output, allocator, record);
    }
    try output.appendSlice(allocator, "]}");

    return output.toOwnedSlice(allocator);
}

fn appendRecordJson(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    record: state_mod.StateRecord,
) !void {
    try output.append(allocator, '{');
    try appendStringField(output, allocator, "resource_id", record.resource_id, false);
    try appendStringField(output, allocator, "type_name", record.type_name, true);
    try appendStringField(output, allocator, "logical_id", record.logical_id, true);
    try appendStringField(output, allocator, "inputs_hash", record.inputs_hash, true);
    try appendStringField(output, allocator, "status", statusName(record.status), true);
    try output.append(allocator, '}');
}

fn outputsJsonAlloc(
    allocator: std.mem.Allocator,
    outputs: []const stack_registry.OutputEntry,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, "{\"outputs\":[");
    for (outputs, 0..) |entry, index| {
        if (index != 0) try output.append(allocator, ',');

        const redacted = entry.secret or zstd.Secrets.containsSecret(entry.value);
        const value = if (redacted) zstd.Secrets.redacted else entry.value;

        try output.append(allocator, '{');
        try appendStringField(&output, allocator, "name", entry.name, false);
        try appendStringField(&output, allocator, "value", value, true);
        try appendBoolField(&output, allocator, "secret", redacted, true);
        try output.append(allocator, '}');
    }
    try output.appendSlice(allocator, "]}");

    return output.toOwnedSlice(allocator);
}

fn appendStringField(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    prefix_comma: bool,
) !void {
    if (prefix_comma) try output.append(allocator, ',');

    const escaped_name = try zstd.Json.escapeStringAlloc(allocator, name);
    defer allocator.free(escaped_name);
    const escaped_value = try zstd.Json.escapeStringAlloc(allocator, value);
    defer allocator.free(escaped_value);

    try output.print(allocator, "\"{s}\":\"{s}\"", .{ escaped_name, escaped_value });
}

fn appendBoolField(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: bool,
    prefix_comma: bool,
) !void {
    if (prefix_comma) try output.append(allocator, ',');

    const escaped_name = try zstd.Json.escapeStringAlloc(allocator, name);
    defer allocator.free(escaped_name);
    try output.print(allocator, "\"{s}\":{}", .{ escaped_name, value });
}

fn parseResources(allocator: std.mem.Allocator, content: []const u8) !LoadedResources {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, content, .{}) catch
        return error.InvalidStateFile;

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidStateFile,
    };
    const resources = (root.get("resources") orelse return error.InvalidStateFile);
    const items = switch (resources) {
        .array => |array| array.items,
        else => return error.InvalidStateFile,
    };

    var store = state_mod.InMemoryStateStore.init(allocator);
    errdefer store.deinit();

    for (items) |item| {
        const object = switch (item) {
            .object => |object| object,
            else => return error.InvalidStateFile,
        };

        const record = state_mod.StateRecord{
            .resource_id = try arena_allocator.dupe(u8, try jsonString(object, "resource_id")),
            .type_name = try arena_allocator.dupe(u8, try jsonString(object, "type_name")),
            .logical_id = try arena_allocator.dupe(u8, try jsonString(object, "logical_id")),
            .inputs_hash = try arena_allocator.dupe(u8, try jsonString(object, "inputs_hash")),
            .status = try parseStatus(try jsonString(object, "status")),
        };
        try store.put(record);
    }

    return .{
        .arena = arena,
        .store = store,
    };
}

fn parseOutputs(allocator: std.mem.Allocator, content: []const u8) !LoadedOutputs {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, content, .{}) catch
        return error.InvalidStateFile;

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidStateFile,
    };
    const outputs = (root.get("outputs") orelse return error.InvalidStateFile);
    const json_items = switch (outputs) {
        .array => |array| array.items,
        else => return error.InvalidStateFile,
    };

    const items = try arena_allocator.alloc(OutputRecord, json_items.len);
    for (json_items, 0..) |item, index| {
        const object = switch (item) {
            .object => |object| object,
            else => return error.InvalidStateFile,
        };
        items[index] = .{
            .name = try arena_allocator.dupe(u8, try jsonString(object, "name")),
            .value = try arena_allocator.dupe(u8, try jsonString(object, "value")),
            .secret = try jsonBool(object, "secret"),
        };
    }

    return .{
        .arena = arena,
        .items = items,
    };
}

fn jsonString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.InvalidStateFile;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidStateFile,
    };
}

fn jsonBool(object: std.json.ObjectMap, field: []const u8) !bool {
    const value = object.get(field) orelse return error.InvalidStateFile;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidStateFile,
    };
}

pub fn statusName(status: state_mod.ResourceStatus) []const u8 {
    return switch (status) {
        .planned => "planned",
        .creating => "creating",
        .created => "created",
        .updating => "updating",
        .updated => "updated",
        .replacing => "replacing",
        .deleting => "deleting",
        .deleted => "deleted",
        .failed => "failed",
        .tainted => "tainted",
        .adopted => "adopted",
    };
}

pub fn parseStatus(value: []const u8) StateFileError!state_mod.ResourceStatus {
    inline for (@typeInfo(state_mod.ResourceStatus).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) {
            return @field(state_mod.ResourceStatus, field.name);
        }
    }
    return error.UnknownStatus;
}
