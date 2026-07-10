const std = @import("std");
const zstd = @import("zigeffect_std");
const resource = @import("resource.zig");
const stack_registry = @import("stack_registry.zig");
const state_format = @import("state_format.zig");
const state_mod = @import("state.zig");
const value_mod = @import("value.zig");

pub const StateFileError = error{
    InvalidStateFile,
    MissingStateFile,
    UnsupportedStateVersion,
    UnknownStatus,
};

pub const FileStore = struct {
    ptr: *anyopaque,
    readFileAllocFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8,
    writeFileFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    atomicWriteFileFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!void,
    createExclusiveFileFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    deleteFileFn: *const fn (*anyopaque, []const u8) anyerror!void,
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

    pub fn atomicWriteFile(
        self: FileStore,
        allocator: std.mem.Allocator,
        path: []const u8,
        content: []const u8,
    ) anyerror!void {
        try self.atomicWriteFileFn(self.ptr, allocator, path, content);
    }

    pub fn createExclusiveFile(self: FileStore, path: []const u8, content: []const u8) anyerror!void {
        try self.createExclusiveFileFn(self.ptr, path, content);
    }

    pub fn deleteFile(self: FileStore, path: []const u8) anyerror!void {
        try self.deleteFileFn(self.ptr, path);
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
        .atomicWriteFileFn = memoryAtomicWriteFile,
        .createExclusiveFileFn = memoryCreateExclusiveFile,
        .deleteFileFn = memoryDeleteFile,
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

fn memoryAtomicWriteFile(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
) anyerror!void {
    _ = allocator;
    const fs: *zstd.FileSystem.MemoryFileSystem = @ptrCast(@alignCast(raw));
    try fs.atomicWriteFile(path, content);
}

fn memoryCreateExclusiveFile(raw: *anyopaque, path: []const u8, content: []const u8) anyerror!void {
    const fs: *zstd.FileSystem.MemoryFileSystem = @ptrCast(@alignCast(raw));
    if (fs.exists(path)) return error.PathAlreadyExists;
    try fs.writeFile(path, content);
}

fn memoryDeleteFile(raw: *anyopaque, path: []const u8) anyerror!void {
    const fs: *zstd.FileSystem.MemoryFileSystem = @ptrCast(@alignCast(raw));
    if (!fs.exists(path)) return error.FileNotFound;
    fs.deleteFile(path);
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
            .atomicWriteFileFn = localAtomicWriteFile,
            .createExclusiveFileFn = localCreateExclusiveFile,
            .deleteFileFn = localDeleteFile,
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

    fn localAtomicWriteFile(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        path: []const u8,
        content: []const u8,
    ) anyerror!void {
        const fs: *zstd.FileSystem.LocalFileSystem = @ptrCast(@alignCast(raw));
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            try fs.dir.createDirPath(fs.io, path[0..slash]);
        }
        const temporary_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(temporary_path);
        try fs.writeFile(temporary_path, content);
        fs.dir.rename(temporary_path, fs.dir.*, path, fs.io) catch |err| {
            fs.deleteFile(temporary_path) catch {};
            return err;
        };
    }

    fn localCreateExclusiveFile(raw: *anyopaque, path: []const u8, content: []const u8) anyerror!void {
        const fs: *zstd.FileSystem.LocalFileSystem = @ptrCast(@alignCast(raw));
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            try fs.dir.createDirPath(fs.io, path[0..slash]);
        }
        try fs.dir.writeFile(fs.io, .{
            .sub_path = path,
            .data = content,
            .flags = .{ .exclusive = true },
        });
    }

    fn localDeleteFile(raw: *anyopaque, path: []const u8) anyerror!void {
        const fs: *zstd.FileSystem.LocalFileSystem = @ptrCast(@alignCast(raw));
        try fs.deleteFile(path);
    }

    fn localExists(raw: *anyopaque, path: []const u8) anyerror!bool {
        const fs: *zstd.FileSystem.LocalFileSystem = @ptrCast(@alignCast(raw));
        return fs.exists(path);
    }
};

pub const LockOptions = struct {
    owner_id: []const u8,
    command: []const u8,
    acquired_at_millis: u64,
    expires_at_millis: ?u64 = null,
};

pub const LockMetadata = struct {
    lineage_id: []const u8,
    owner_id: []const u8,
    command: []const u8,
    acquired_at_millis: u64,
    expires_at_millis: ?u64 = null,

    pub fn isStale(self: LockMetadata, now_millis: u64, stale_after_millis: u64) bool {
        if (self.expires_at_millis) |expires| return now_millis >= expires;
        return now_millis -| self.acquired_at_millis >= stale_after_millis;
    }

    pub fn isExpired(self: LockMetadata, now_millis: u64) bool {
        return if (self.expires_at_millis) |expires| now_millis >= expires else false;
    }
};

pub const LoadedLock = struct {
    arena: std.heap.ArenaAllocator,
    metadata: LockMetadata,

    pub fn deinit(self: *LoadedLock) void {
        self.arena.deinit();
        self.* = undefined;
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

    pub fn lockPathAlloc(self: Store, stack: []const u8, stage: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, ".ziac/state/{s}/{s}/lock.json", .{ stack, stage });
    }

    pub fn acquireLock(self: Store, stack: []const u8, stage: []const u8, options: LockOptions) !void {
        const path = try self.lockPathAlloc(stack, stage);
        defer self.allocator.free(path);
        const lineage = try state_format.lineageAlloc(self.allocator, stack, stage);
        defer self.allocator.free(lineage);
        const content = try lockJsonAlloc(self.allocator, .{
            .lineage_id = lineage,
            .owner_id = options.owner_id,
            .command = options.command,
            .acquired_at_millis = options.acquired_at_millis,
            .expires_at_millis = options.expires_at_millis,
        });
        defer self.allocator.free(content);
        self.files.createExclusiveFile(path, content) catch |err| switch (err) {
            error.PathAlreadyExists => return error.LockConflict,
            else => return err,
        };
    }

    pub fn inspectLock(self: Store, stack: []const u8, stage: []const u8) !LoadedLock {
        const path = try self.lockPathAlloc(stack, stage);
        defer self.allocator.free(path);
        const content = self.files.readFileAlloc(self.allocator, path) catch |err| switch (err) {
            error.FileNotFound => return error.MissingLock,
            else => return err,
        };
        defer self.allocator.free(content);
        return parseLock(self.allocator, content);
    }

    pub fn hasLock(self: Store, stack: []const u8, stage: []const u8) !bool {
        const path = try self.lockPathAlloc(stack, stage);
        defer self.allocator.free(path);
        return self.files.exists(path);
    }

    pub fn releaseLock(self: Store, stack: []const u8, stage: []const u8, owner_id: []const u8) !void {
        var lock = try self.inspectLock(stack, stage);
        defer lock.deinit();
        if (!std.mem.eql(u8, lock.metadata.owner_id, owner_id)) return error.LockOwnershipMismatch;
        try self.deleteLockFile(stack, stage);
    }

    pub fn forceUnlock(
        self: Store,
        stack: []const u8,
        stage: []const u8,
        expected_lineage: []const u8,
        override_lineage: bool,
    ) !void {
        var lock = try self.inspectLock(stack, stage);
        defer lock.deinit();
        if (!override_lineage and !std.mem.eql(u8, lock.metadata.lineage_id, expected_lineage)) {
            return error.LockLineageMismatch;
        }
        try self.deleteLockFile(stack, stage);
    }

    fn deleteLockFile(self: Store, stack: []const u8, stage: []const u8) !void {
        const path = try self.lockPathAlloc(stack, stage);
        defer self.allocator.free(path);
        try self.files.deleteFile(path);
    }

    pub fn saveResources(
        self: Store,
        stack: []const u8,
        stage: []const u8,
        state_store: *state_mod.InMemoryStateStore,
    ) !void {
        const path = try self.resourcesPathAlloc(stack, stage);
        defer self.allocator.free(path);

        const content = try resourcesJsonAlloc(self.allocator, stack, stage, state_store);
        defer self.allocator.free(content);

        try self.files.atomicWriteFile(self.allocator, path, content);
    }

    pub fn loadResources(self: Store, stack: []const u8, stage: []const u8) !LoadedResources {
        const path = try self.resourcesPathAlloc(stack, stage);
        defer self.allocator.free(path);

        const content = self.files.readFileAlloc(self.allocator, path) catch |err| switch (err) {
            error.FileNotFound => return error.MissingStateFile,
            else => return err,
        };
        defer self.allocator.free(content);

        return parseResources(self.allocator, content, stack, stage);
    }

    pub fn loadResourcesOrEmpty(self: Store, stack: []const u8, stage: []const u8) !LoadedResources {
        return self.loadResources(stack, stage) catch |err| switch (err) {
            error.MissingStateFile => emptyResources(self.allocator, stack, stage),
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

        try self.files.atomicWriteFile(self.allocator, path, content);
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

pub fn lockJsonAlloc(allocator: std.mem.Allocator, metadata: LockMetadata) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    try appendIntField(&output, allocator, "format_version", 2, false);
    try appendStringField(&output, allocator, "lineage_id", metadata.lineage_id, true);
    try appendStringField(&output, allocator, "owner_id", metadata.owner_id, true);
    try appendStringField(&output, allocator, "command", metadata.command, true);
    try appendIntField(&output, allocator, "acquired_at_millis", metadata.acquired_at_millis, true);
    try appendOptionalIntField(&output, allocator, "expires_at_millis", metadata.expires_at_millis, true);
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

pub fn parseLock(allocator: std.mem.Allocator, content: []const u8) !LoadedLock {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, content, .{}) catch
        return error.InvalidLockFile;
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidLockFile,
    };
    const format_version = try jsonU32(root, "format_version");
    if (format_version != 1 and format_version != 2) return error.InvalidLockFile;
    return .{
        .arena = arena,
        .metadata = .{
            .lineage_id = try arena_allocator.dupe(u8, try jsonString(root, "lineage_id")),
            .owner_id = try arena_allocator.dupe(u8, try jsonString(root, "owner_id")),
            .command = try arena_allocator.dupe(u8, try jsonString(root, "command")),
            .acquired_at_millis = try jsonU64(root, "acquired_at_millis"),
            .expires_at_millis = if (format_version == 2) try jsonOptionalU64(root, "expires_at_millis") else null,
        },
    };
}

pub const LoadedResources = struct {
    arena: std.heap.ArenaAllocator,
    store: state_mod.InMemoryStateStore,
    source_format_version: u32,

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

pub fn emptyResources(
    allocator: std.mem.Allocator,
    stack: []const u8,
    stage: []const u8,
) !LoadedResources {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var store = state_mod.InMemoryStateStore.init(allocator);
    const lineage = try state_format.lineageAlloc(allocator, stack, stage);
    defer allocator.free(lineage);
    store.setLineage(lineage);

    return .{
        .arena = arena,
        .store = store,
        .source_format_version = state_format.current_version,
    };
}

pub fn resourcesJsonAlloc(
    allocator: std.mem.Allocator,
    stack: []const u8,
    stage: []const u8,
    state_store: *state_mod.InMemoryStateStore,
) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var snapshot = try state_store.snapshotAlloc(allocator);
    defer snapshot.deinit();

    const lineage = try state_format.lineageAlloc(allocator, stack, stage);
    defer allocator.free(lineage);

    try output.append(allocator, '{');
    try appendIntField(&output, allocator, "format_version", state_format.current_version, false);
    try appendStringField(&output, allocator, "lineage_id", lineage, true);
    try appendIntField(&output, allocator, "serial", snapshot.serial, true);
    try appendStringField(&output, allocator, "stack", stack, true);
    try appendStringField(&output, allocator, "stage", stage, true);
    try output.appendSlice(allocator, ",\"resources\":[");
    for (snapshot.records, 0..) |record, index| {
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
    try appendStringField(output, allocator, "provider", @tagName(record.provider), true);
    try appendStringField(output, allocator, "type_name", record.type_name, true);
    try appendIntField(output, allocator, "schema_version", record.schema_version, true);
    try appendStringField(output, allocator, "logical_id", record.logical_id, true);
    try appendOptionalStringField(output, allocator, "physical_id", record.physical_id, true);
    try appendStringField(output, allocator, "desired_hash", record.desired_hash, true);
    try appendOptionalStringField(output, allocator, "observed_hash", record.observed_hash, true);
    try appendStringArrayField(output, allocator, "dependencies", record.dependencies, true);
    try appendStateOutputsField(output, allocator, record.outputs, true);
    try appendBoolField(output, allocator, "protect", record.protect, true);
    try appendBoolField(output, allocator, "retain_on_delete", record.retain_on_delete, true);
    try appendStringField(output, allocator, "status", statusName(record.status), true);
    try appendOptionalStringField(output, allocator, "operation_handle", record.operation_handle, true);
    try output.append(allocator, '}');
}

fn appendStateOutputsField(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    outputs: []const state_mod.StateOutput,
    prefix_comma: bool,
) !void {
    if (prefix_comma) try output.append(allocator, ',');
    try output.appendSlice(allocator, "\"outputs\":[");
    for (outputs, 0..) |entry, index| {
        if (index != 0) try output.append(allocator, ',');
        try output.append(allocator, '{');
        try appendStringField(output, allocator, "name", entry.name, false);
        try output.appendSlice(allocator, ",\"value\":");
        const value_json = try entry.value.canonicalJsonAlloc(allocator);
        defer allocator.free(value_json);
        try output.appendSlice(allocator, value_json);
        try output.append(allocator, '}');
    }
    try output.append(allocator, ']');
}

pub fn outputsJsonAlloc(
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

fn appendOptionalStringField(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: ?[]const u8,
    prefix_comma: bool,
) !void {
    if (value) |inner| return appendStringField(output, allocator, name, inner, prefix_comma);
    if (prefix_comma) try output.append(allocator, ',');
    const escaped_name = try zstd.Json.escapeStringAlloc(allocator, name);
    defer allocator.free(escaped_name);
    try output.print(allocator, "\"{s}\":null", .{escaped_name});
}

fn appendIntField(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: anytype,
    prefix_comma: bool,
) !void {
    if (prefix_comma) try output.append(allocator, ',');
    const escaped_name = try zstd.Json.escapeStringAlloc(allocator, name);
    defer allocator.free(escaped_name);
    try output.print(allocator, "\"{s}\":{d}", .{ escaped_name, value });
}

fn appendOptionalIntField(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: ?u64,
    prefix_comma: bool,
) !void {
    if (value) |inner| return appendIntField(output, allocator, name, inner, prefix_comma);
    if (prefix_comma) try output.append(allocator, ',');
    const escaped_name = try zstd.Json.escapeStringAlloc(allocator, name);
    defer allocator.free(escaped_name);
    try output.print(allocator, "\"{s}\":null", .{escaped_name});
}

fn appendStringArrayField(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    values: []const []const u8,
    prefix_comma: bool,
) !void {
    if (prefix_comma) try output.append(allocator, ',');
    const escaped_name = try zstd.Json.escapeStringAlloc(allocator, name);
    defer allocator.free(escaped_name);
    try output.print(allocator, "\"{s}\":[", .{escaped_name});
    for (values, 0..) |value, index| {
        if (index != 0) try output.append(allocator, ',');
        const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(encoded);
        try output.appendSlice(allocator, encoded);
    }
    try output.append(allocator, ']');
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

pub fn parseResources(
    allocator: std.mem.Allocator,
    content: []const u8,
    expected_stack: []const u8,
    expected_stage: []const u8,
) !LoadedResources {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, content, .{}) catch
        return error.InvalidStateFile;

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidStateFile,
    };

    const source_version: u32 = if (root.get("format_version")) |version|
        try jsonU32Value(version)
    else
        1;
    if (source_version > state_format.current_version or source_version == 0) {
        return error.UnsupportedStateVersion;
    }

    var store = state_mod.InMemoryStateStore.init(allocator);
    errdefer store.deinit();

    if (source_version == 1) {
        const lineage = try state_format.lineageAlloc(allocator, expected_stack, expected_stage);
        defer allocator.free(lineage);
        store.setLineage(lineage);
        try parseVersionOneResources(&store, root);
        store.serial = 0;
    } else {
        try validateEnvelope(allocator, root, expected_stack, expected_stage);
        store.setLineage(try jsonString(root, "lineage_id"));
        const serial = try jsonU64(root, "serial");
        try parseVersionTwoResources(allocator, &store, root);
        store.serial = serial;
    }

    return .{
        .arena = arena,
        .store = store,
        .source_format_version = source_version,
    };
}

fn validateEnvelope(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    expected_stack: []const u8,
    expected_stage: []const u8,
) !void {
    const expected_lineage = try state_format.lineageAlloc(allocator, expected_stack, expected_stage);
    defer allocator.free(expected_lineage);
    if (!std.mem.eql(u8, expected_lineage, try jsonString(root, "lineage_id"))) return error.InvalidStateFile;
    if (!std.mem.eql(u8, expected_stack, try jsonString(root, "stack"))) return error.InvalidStateFile;
    if (!std.mem.eql(u8, expected_stage, try jsonString(root, "stage"))) return error.InvalidStateFile;
}

fn resourceItems(root: std.json.ObjectMap) ![]const std.json.Value {
    const resources = root.get("resources") orelse return error.InvalidStateFile;
    return switch (resources) {
        .array => |array| array.items,
        else => error.InvalidStateFile,
    };
}

fn parseVersionOneResources(
    store: *state_mod.InMemoryStateStore,
    root: std.json.ObjectMap,
) !void {
    for (try resourceItems(root)) |item| {
        const object = switch (item) {
            .object => |inner| inner,
            else => return error.InvalidStateFile,
        };
        const type_name = try jsonString(object, "type_name");
        try store.put(.{
            .resource_id = try jsonString(object, "resource_id"),
            .provider = providerFromTypeName(type_name),
            .type_name = type_name,
            .schema_version = 1,
            .logical_id = try jsonString(object, "logical_id"),
            .desired_hash = try jsonString(object, "inputs_hash"),
            .status = try parseStatus(try jsonString(object, "status")),
        });
    }
}

fn parseVersionTwoResources(
    allocator: std.mem.Allocator,
    store: *state_mod.InMemoryStateStore,
    root: std.json.ObjectMap,
) !void {
    for (try resourceItems(root)) |item| {
        const object = switch (item) {
            .object => |inner| inner,
            else => return error.InvalidStateFile,
        };
        const provider = std.meta.stringToEnum(resource.ProviderId, try jsonString(object, "provider")) orelse
            return error.InvalidStateFile;
        const dependencies = try jsonStringArrayAlloc(allocator, object, "dependencies");
        defer freeStringArray(allocator, dependencies);
        const outputs = try parseStateOutputsAlloc(allocator, object);
        defer freeStateOutputs(allocator, outputs);

        try store.put(.{
            .resource_id = try jsonString(object, "resource_id"),
            .provider = provider,
            .type_name = try jsonString(object, "type_name"),
            .schema_version = try jsonU32(object, "schema_version"),
            .logical_id = try jsonString(object, "logical_id"),
            .physical_id = try jsonOptionalString(object, "physical_id"),
            .desired_hash = try jsonString(object, "desired_hash"),
            .observed_hash = try jsonOptionalString(object, "observed_hash"),
            .dependencies = dependencies,
            .outputs = outputs,
            .protect = try jsonBoolDefault(object, "protect", false),
            .retain_on_delete = try jsonBoolDefault(object, "retain_on_delete", false),
            .status = try parseStatus(try jsonString(object, "status")),
            .operation_handle = try jsonOptionalString(object, "operation_handle"),
        });
    }
}

fn parseStateOutputsAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) ![]const state_mod.StateOutput {
    const raw_outputs = object.get("outputs") orelse return error.InvalidStateFile;
    const items = switch (raw_outputs) {
        .array => |array| array.items,
        else => return error.InvalidStateFile,
    };
    const outputs = try allocator.alloc(state_mod.StateOutput, items.len);
    errdefer allocator.free(outputs);

    var initialized: usize = 0;
    errdefer {
        for (outputs[0..initialized]) |*output| {
            allocator.free(output.name);
            output.value.deinit(allocator);
        }
    }
    for (items, 0..) |item, index| {
        const output_object = switch (item) {
            .object => |inner| inner,
            else => return error.InvalidStateFile,
        };
        const name = try allocator.dupe(u8, try jsonString(output_object, "name"));
        errdefer allocator.free(name);
        const raw_value = output_object.get("value") orelse return error.InvalidStateFile;
        const encoded = try std.json.Stringify.valueAlloc(allocator, raw_value, .{});
        defer allocator.free(encoded);
        var parsed_value = value_mod.Value.parseJsonAlloc(allocator, encoded) catch return error.InvalidStateFile;
        errdefer parsed_value.deinit(allocator);
        outputs[index] = .{ .name = name, .value = parsed_value };
        initialized += 1;
    }
    return outputs;
}

fn freeStateOutputs(allocator: std.mem.Allocator, outputs: []const state_mod.StateOutput) void {
    const mutable_outputs: []state_mod.StateOutput = @constCast(outputs);
    for (mutable_outputs) |*output| {
        allocator.free(output.name);
        output.value.deinit(allocator);
    }
    allocator.free(outputs);
}

fn jsonStringArrayAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field: []const u8,
) ![]const []const u8 {
    const raw_values = object.get(field) orelse return error.InvalidStateFile;
    const items = switch (raw_values) {
        .array => |array| array.items,
        else => return error.InvalidStateFile,
    };
    const values = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(values);

    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |value| allocator.free(value);
    }
    for (items, 0..) |item, index| {
        const string = switch (item) {
            .string => |inner| inner,
            else => return error.InvalidStateFile,
        };
        values[index] = try allocator.dupe(u8, string);
        initialized += 1;
    }
    return values;
}

fn freeStringArray(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn providerFromTypeName(type_name: []const u8) resource.ProviderId {
    if (std.mem.startsWith(u8, type_name, "gcp.")) return .gcp;
    if (std.mem.startsWith(u8, type_name, "cockroach.")) return .cockroach;
    return .local;
}

pub fn parseOutputs(allocator: std.mem.Allocator, content: []const u8) !LoadedOutputs {
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

fn jsonOptionalString(object: std.json.ObjectMap, field: []const u8) !?[]const u8 {
    const value = object.get(field) orelse return error.InvalidStateFile;
    return switch (value) {
        .null => null,
        .string => |string| string,
        else => error.InvalidStateFile,
    };
}

fn jsonU32(object: std.json.ObjectMap, field: []const u8) !u32 {
    const value = object.get(field) orelse return error.InvalidStateFile;
    return jsonU32Value(value);
}

fn jsonU32Value(value: std.json.Value) !u32 {
    const integer = switch (value) {
        .integer => |inner| inner,
        else => return error.InvalidStateFile,
    };
    if (integer < 0 or integer > std.math.maxInt(u32)) return error.InvalidStateFile;
    return @intCast(integer);
}

fn jsonU64(object: std.json.ObjectMap, field: []const u8) !u64 {
    const value = object.get(field) orelse return error.InvalidStateFile;
    const integer = switch (value) {
        .integer => |inner| inner,
        else => return error.InvalidStateFile,
    };
    if (integer < 0) return error.InvalidStateFile;
    return @intCast(integer);
}

fn jsonOptionalU64(object: std.json.ObjectMap, field: []const u8) !?u64 {
    const value = object.get(field) orelse return error.InvalidLockFile;
    return switch (value) {
        .null => null,
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidLockFile,
        else => error.InvalidLockFile,
    };
}

fn jsonBool(object: std.json.ObjectMap, field: []const u8) !bool {
    const value = object.get(field) orelse return error.InvalidStateFile;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidStateFile,
    };
}

fn jsonBoolDefault(object: std.json.ObjectMap, field: []const u8, default: bool) !bool {
    if (object.get(field) == null) return default;
    return jsonBool(object, field);
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
