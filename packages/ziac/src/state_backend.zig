const std = @import("std");
const fx = @import("zigeffect_std").fx;
const local_state = @import("local_state.zig");
const stack_registry = @import("stack_registry.zig");
const state_mod = @import("state.zig");

pub const Precondition = union(enum) {
    absent,
    generation: []const u8,
};

pub const Object = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    generation: []u8,

    pub fn deinit(self: *Object) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.generation);
        self.* = undefined;
    }
};

pub const PutResult = struct {
    allocator: std.mem.Allocator,
    generation: []u8,

    pub fn deinit(self: *PutResult) void {
        self.allocator.free(self.generation);
        self.* = undefined;
    }
};

pub const ObjectStore = struct {
    ptr: *anyopaque,
    getFn: *const fn (*anyopaque, []const u8) anyerror!Object,
    putFn: *const fn (*anyopaque, []const u8, []const u8, Precondition) anyerror!PutResult,
    deleteFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,

    pub fn get(self: ObjectStore, key: []const u8) anyerror!Object {
        return self.getFn(self.ptr, key);
    }

    pub fn put(
        self: ObjectStore,
        key: []const u8,
        bytes: []const u8,
        precondition: Precondition,
    ) anyerror!PutResult {
        return self.putFn(self.ptr, key, bytes, precondition);
    }

    pub fn delete(self: ObjectStore, key: []const u8, generation: []const u8) anyerror!void {
        return self.deleteFn(self.ptr, key, generation);
    }
};

const MemoryRecord = struct {
    key: []u8,
    bytes: []u8,
    generation: u64,
};

pub const MemoryObjectStore = struct {
    allocator: std.mem.Allocator,
    objects: std.StringHashMap(MemoryRecord),
    next_generation: u64 = 1,
    mutex: fx.SpinLock = .{},

    pub fn init(allocator: std.mem.Allocator) MemoryObjectStore {
        return .{
            .allocator = allocator,
            .objects = std.StringHashMap(MemoryRecord).init(allocator),
        };
    }

    pub fn deinit(self: *MemoryObjectStore) void {
        var iterator = self.objects.valueIterator();
        while (iterator.next()) |record| {
            self.allocator.free(record.key);
            self.allocator.free(record.bytes);
        }
        self.objects.deinit();
        self.* = undefined;
    }

    pub fn objectStore(self: *MemoryObjectStore) ObjectStore {
        return .{ .ptr = self, .getFn = get, .putFn = put, .deleteFn = delete };
    }

    pub fn content(self: *MemoryObjectStore, key: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.objects.get(key)) |record| record.bytes else null;
    }

    fn get(raw: *anyopaque, key: []const u8) anyerror!Object {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        const record = self.objects.get(key) orelse return error.NotFound;
        const bytes = try self.allocator.dupe(u8, record.bytes);
        errdefer self.allocator.free(bytes);
        const generation = try std.fmt.allocPrint(self.allocator, "{d}", .{record.generation});
        return .{ .allocator = self.allocator, .bytes = bytes, .generation = generation };
    }

    fn put(
        raw: *anyopaque,
        key: []const u8,
        bytes: []const u8,
        precondition: Precondition,
    ) anyerror!PutResult {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        const existing = self.objects.getPtr(key);
        switch (precondition) {
            .absent => if (existing != null) return error.Conflict,
            .generation => |expected| {
                const record = existing orelse return error.Conflict;
                const actual = try std.fmt.allocPrint(self.allocator, "{d}", .{record.generation});
                defer self.allocator.free(actual);
                if (!std.mem.eql(u8, actual, expected)) return error.Conflict;
            },
        }
        const owned_bytes = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned_bytes);
        const generation = self.next_generation;
        self.next_generation = std.math.add(u64, self.next_generation, 1) catch return error.GenerationOverflow;
        if (existing) |record| {
            self.allocator.free(record.bytes);
            record.bytes = owned_bytes;
            record.generation = generation;
        } else {
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            try self.objects.put(owned_key, .{
                .key = owned_key,
                .bytes = owned_bytes,
                .generation = generation,
            });
        }
        return .{
            .allocator = self.allocator,
            .generation = try std.fmt.allocPrint(self.allocator, "{d}", .{generation}),
        };
    }

    fn delete(raw: *anyopaque, key: []const u8, generation: []const u8) anyerror!void {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        const record = self.objects.get(key) orelse return error.NotFound;
        const actual = try std.fmt.allocPrint(self.allocator, "{d}", .{record.generation});
        defer self.allocator.free(actual);
        if (!std.mem.eql(u8, actual, generation)) return error.Conflict;
        const removed = self.objects.fetchRemove(key) orelse unreachable;
        self.allocator.free(removed.value.key);
        self.allocator.free(removed.value.bytes);
    }
};

pub const Store = struct {
    ptr: *anyopaque,
    saveResourcesFn: *const fn (*anyopaque, []const u8, []const u8, *state_mod.InMemoryStateStore) anyerror!void,
    loadResourcesFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!local_state.LoadedResources,
    loadResourcesOrEmptyFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!local_state.LoadedResources,
    saveOutputsFn: *const fn (*anyopaque, []const u8, []const u8, []const stack_registry.OutputEntry) anyerror!void,
    loadOutputsFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!local_state.LoadedOutputs,
    acquireLockFn: *const fn (*anyopaque, []const u8, []const u8, local_state.LockOptions) anyerror!void,
    inspectLockFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!local_state.LoadedLock,
    hasLockFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!bool,
    renewLockFn: *const fn (*anyopaque, []const u8, []const u8, []const u8, u64) anyerror!void,
    releaseLockFn: *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void,
    forceUnlockFn: *const fn (*anyopaque, []const u8, []const u8, []const u8, bool) anyerror!void,

    pub fn saveResources(self: Store, stack: []const u8, stage: []const u8, state: *state_mod.InMemoryStateStore) !void {
        return self.saveResourcesFn(self.ptr, stack, stage, state);
    }

    pub fn loadResources(self: Store, stack: []const u8, stage: []const u8) !local_state.LoadedResources {
        return self.loadResourcesFn(self.ptr, stack, stage);
    }

    pub fn loadResourcesOrEmpty(self: Store, stack: []const u8, stage: []const u8) !local_state.LoadedResources {
        return self.loadResourcesOrEmptyFn(self.ptr, stack, stage);
    }

    pub fn saveOutputs(self: Store, stack: []const u8, stage: []const u8, outputs: []const stack_registry.OutputEntry) !void {
        return self.saveOutputsFn(self.ptr, stack, stage, outputs);
    }

    pub fn loadOutputs(self: Store, stack: []const u8, stage: []const u8) !local_state.LoadedOutputs {
        return self.loadOutputsFn(self.ptr, stack, stage);
    }

    pub fn acquireLock(self: Store, stack: []const u8, stage: []const u8, options: local_state.LockOptions) !void {
        return self.acquireLockFn(self.ptr, stack, stage, options);
    }

    pub fn inspectLock(self: Store, stack: []const u8, stage: []const u8) !local_state.LoadedLock {
        return self.inspectLockFn(self.ptr, stack, stage);
    }

    pub fn hasLock(self: Store, stack: []const u8, stage: []const u8) !bool {
        return self.hasLockFn(self.ptr, stack, stage);
    }

    pub fn renewLock(self: Store, stack: []const u8, stage: []const u8, owner_id: []const u8, now_millis: u64) !void {
        return self.renewLockFn(self.ptr, stack, stage, owner_id, now_millis);
    }

    pub fn releaseLock(self: Store, stack: []const u8, stage: []const u8, owner_id: []const u8) !void {
        return self.releaseLockFn(self.ptr, stack, stage, owner_id);
    }

    pub fn forceUnlock(self: Store, stack: []const u8, stage: []const u8, expected_lineage: []const u8, override_lineage: bool) !void {
        return self.forceUnlockFn(self.ptr, stack, stage, expected_lineage, override_lineage);
    }
};

pub const Local = struct {
    delegate: local_state.Store,

    pub fn init(delegate: local_state.Store) Local {
        return .{ .delegate = delegate };
    }

    pub fn store(self: *Local) Store {
        return storeFor(self, Local);
    }

    fn saveResources(raw: *anyopaque, stack: []const u8, stage: []const u8, state: *state_mod.InMemoryStateStore) !void {
        return as(Local, raw).delegate.saveResources(stack, stage, state);
    }
    fn loadResources(raw: *anyopaque, stack: []const u8, stage: []const u8) !local_state.LoadedResources {
        return as(Local, raw).delegate.loadResources(stack, stage);
    }
    fn loadResourcesOrEmpty(raw: *anyopaque, stack: []const u8, stage: []const u8) !local_state.LoadedResources {
        return as(Local, raw).delegate.loadResourcesOrEmpty(stack, stage);
    }
    fn saveOutputs(raw: *anyopaque, stack: []const u8, stage: []const u8, outputs: []const stack_registry.OutputEntry) !void {
        return as(Local, raw).delegate.saveOutputs(stack, stage, outputs);
    }
    fn loadOutputs(raw: *anyopaque, stack: []const u8, stage: []const u8) !local_state.LoadedOutputs {
        return as(Local, raw).delegate.loadOutputs(stack, stage);
    }
    fn acquireLock(raw: *anyopaque, stack: []const u8, stage: []const u8, options: local_state.LockOptions) !void {
        return as(Local, raw).delegate.acquireLock(stack, stage, options);
    }
    fn inspectLock(raw: *anyopaque, stack: []const u8, stage: []const u8) !local_state.LoadedLock {
        return as(Local, raw).delegate.inspectLock(stack, stage);
    }
    fn hasLock(raw: *anyopaque, stack: []const u8, stage: []const u8) !bool {
        return as(Local, raw).delegate.hasLock(stack, stage);
    }
    fn renewLock(raw: *anyopaque, stack: []const u8, stage: []const u8, owner_id: []const u8, _: u64) !void {
        var lock = try as(Local, raw).delegate.inspectLock(stack, stage);
        defer lock.deinit();
        if (!std.mem.eql(u8, lock.metadata.owner_id, owner_id)) return error.LockOwnershipMismatch;
    }
    fn releaseLock(raw: *anyopaque, stack: []const u8, stage: []const u8, owner_id: []const u8) !void {
        return as(Local, raw).delegate.releaseLock(stack, stage, owner_id);
    }
    fn forceUnlock(raw: *anyopaque, stack: []const u8, stage: []const u8, expected: []const u8, override: bool) !void {
        return as(Local, raw).delegate.forceUnlock(stack, stage, expected, override);
    }
};

pub const RemoteOptions = struct {
    prefix: []const u8 = "ziac/state",
    lease_duration_millis: u64 = 60 * std.time.ms_per_min,
};

pub const Remote = struct {
    allocator: std.mem.Allocator,
    objects: ObjectStore,
    prefix: []u8,
    lease_duration_millis: u64,
    generations: std.StringHashMap([]u8),
    mutex: fx.SpinLock = .{},

    pub fn init(allocator: std.mem.Allocator, objects: ObjectStore, options: RemoteOptions) !Remote {
        try validatePrefix(options.prefix);
        if (options.lease_duration_millis == 0) return error.InvalidLeaseDuration;
        return .{
            .allocator = allocator,
            .objects = objects,
            .prefix = try allocator.dupe(u8, options.prefix),
            .lease_duration_millis = options.lease_duration_millis,
            .generations = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Remote) void {
        var iterator = self.generations.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.generations.deinit();
        self.allocator.free(self.prefix);
        self.* = undefined;
    }

    pub fn store(self: *Remote) Store {
        return storeFor(self, Remote);
    }

    fn saveResources(raw: *anyopaque, stack: []const u8, stage: []const u8, state: *state_mod.InMemoryStateStore) !void {
        const self = as(Remote, raw);
        const key = try self.keyAlloc(stack, stage, "resources.json");
        defer self.allocator.free(key);
        const content = try local_state.resourcesJsonAlloc(self.allocator, stack, stage, state);
        defer self.allocator.free(content);
        try self.putObserved(key, content, error.StateConflict);
    }

    fn loadResources(raw: *anyopaque, stack: []const u8, stage: []const u8) !local_state.LoadedResources {
        const self = as(Remote, raw);
        const key = try self.keyAlloc(stack, stage, "resources.json");
        defer self.allocator.free(key);
        var object = self.objects.get(key) catch |err| switch (err) {
            error.NotFound => {
                self.clearGeneration(key);
                return error.MissingStateFile;
            },
            else => return err,
        };
        defer object.deinit();
        try self.setGeneration(key, object.generation);
        return local_state.parseResources(self.allocator, object.bytes, stack, stage);
    }

    fn loadResourcesOrEmpty(raw: *anyopaque, stack: []const u8, stage: []const u8) !local_state.LoadedResources {
        const self = as(Remote, raw);
        return loadResources(raw, stack, stage) catch |err| switch (err) {
            error.MissingStateFile => local_state.emptyResources(self.allocator, stack, stage),
            else => return err,
        };
    }

    fn saveOutputs(raw: *anyopaque, stack: []const u8, stage: []const u8, outputs: []const stack_registry.OutputEntry) !void {
        const self = as(Remote, raw);
        const key = try self.keyAlloc(stack, stage, "outputs.json");
        defer self.allocator.free(key);
        try self.observeIfUnknown(key);
        const content = try local_state.outputsJsonAlloc(self.allocator, outputs);
        defer self.allocator.free(content);
        try self.putObserved(key, content, error.StateConflict);
    }

    fn loadOutputs(raw: *anyopaque, stack: []const u8, stage: []const u8) !local_state.LoadedOutputs {
        const self = as(Remote, raw);
        const key = try self.keyAlloc(stack, stage, "outputs.json");
        defer self.allocator.free(key);
        var object = self.objects.get(key) catch |err| switch (err) {
            error.NotFound => {
                self.clearGeneration(key);
                return error.MissingStateFile;
            },
            else => return err,
        };
        defer object.deinit();
        try self.setGeneration(key, object.generation);
        return local_state.parseOutputs(self.allocator, object.bytes);
    }

    fn acquireLock(raw: *anyopaque, stack: []const u8, stage: []const u8, options: local_state.LockOptions) !void {
        const self = as(Remote, raw);
        if (options.owner_id.len == 0 or options.command.len == 0) return error.InvalidLock;
        const expires = std.math.add(u64, options.acquired_at_millis, self.lease_duration_millis) catch return error.InvalidLock;
        const lineage = try @import("state_format.zig").lineageAlloc(self.allocator, stack, stage);
        defer self.allocator.free(lineage);
        const metadata = local_state.LockMetadata{
            .lineage_id = lineage,
            .owner_id = options.owner_id,
            .command = options.command,
            .acquired_at_millis = options.acquired_at_millis,
            .expires_at_millis = expires,
        };
        const key = try self.keyAlloc(stack, stage, "lock.json");
        defer self.allocator.free(key);
        const content = try local_state.lockJsonAlloc(self.allocator, metadata);
        defer self.allocator.free(content);
        var created = self.objects.put(key, content, .absent) catch |err| switch (err) {
            error.Conflict => return self.takeExpiredLock(key, metadata, options.acquired_at_millis),
            else => return err,
        };
        created.deinit();
    }

    fn inspectLock(raw: *anyopaque, stack: []const u8, stage: []const u8) !local_state.LoadedLock {
        const self = as(Remote, raw);
        const key = try self.keyAlloc(stack, stage, "lock.json");
        defer self.allocator.free(key);
        var object = self.objects.get(key) catch |err| switch (err) {
            error.NotFound => return error.MissingLock,
            else => return err,
        };
        defer object.deinit();
        return local_state.parseLock(self.allocator, object.bytes);
    }

    fn hasLock(raw: *anyopaque, stack: []const u8, stage: []const u8) !bool {
        const self = as(Remote, raw);
        const key = try self.keyAlloc(stack, stage, "lock.json");
        defer self.allocator.free(key);
        var object = self.objects.get(key) catch |err| switch (err) {
            error.NotFound => return false,
            else => return err,
        };
        object.deinit();
        return true;
    }

    fn renewLock(raw: *anyopaque, stack: []const u8, stage: []const u8, owner_id: []const u8, now_millis: u64) !void {
        const self = as(Remote, raw);
        const key = try self.keyAlloc(stack, stage, "lock.json");
        defer self.allocator.free(key);
        var object = self.objects.get(key) catch |err| switch (err) {
            error.NotFound => return error.MissingLock,
            else => return err,
        };
        defer object.deinit();
        var lock = try local_state.parseLock(self.allocator, object.bytes);
        defer lock.deinit();
        if (!std.mem.eql(u8, lock.metadata.owner_id, owner_id)) return error.LockOwnershipMismatch;
        lock.metadata.expires_at_millis = std.math.add(u64, now_millis, self.lease_duration_millis) catch return error.InvalidLock;
        const content = try local_state.lockJsonAlloc(self.allocator, lock.metadata);
        defer self.allocator.free(content);
        var updated = self.objects.put(key, content, .{ .generation = object.generation }) catch |err| switch (err) {
            error.Conflict => return error.LockConflict,
            else => return err,
        };
        updated.deinit();
    }

    fn releaseLock(raw: *anyopaque, stack: []const u8, stage: []const u8, owner_id: []const u8) !void {
        const self = as(Remote, raw);
        const key = try self.keyAlloc(stack, stage, "lock.json");
        defer self.allocator.free(key);
        var object = self.objects.get(key) catch |err| switch (err) {
            error.NotFound => return error.MissingLock,
            else => return err,
        };
        defer object.deinit();
        var lock = try local_state.parseLock(self.allocator, object.bytes);
        defer lock.deinit();
        if (!std.mem.eql(u8, lock.metadata.owner_id, owner_id)) return error.LockOwnershipMismatch;
        self.objects.delete(key, object.generation) catch |err| switch (err) {
            error.Conflict => return error.LockConflict,
            else => return err,
        };
    }

    fn forceUnlock(raw: *anyopaque, stack: []const u8, stage: []const u8, expected: []const u8, override: bool) !void {
        const self = as(Remote, raw);
        const key = try self.keyAlloc(stack, stage, "lock.json");
        defer self.allocator.free(key);
        var object = self.objects.get(key) catch |err| switch (err) {
            error.NotFound => return error.MissingLock,
            else => return err,
        };
        defer object.deinit();
        var lock = try local_state.parseLock(self.allocator, object.bytes);
        defer lock.deinit();
        if (!override and !std.mem.eql(u8, lock.metadata.lineage_id, expected)) return error.LockLineageMismatch;
        self.objects.delete(key, object.generation) catch |err| switch (err) {
            error.Conflict => return error.LockConflict,
            else => return err,
        };
    }

    fn takeExpiredLock(self: *Remote, key: []const u8, metadata: local_state.LockMetadata, now_millis: u64) !void {
        var existing = self.objects.get(key) catch |err| switch (err) {
            error.NotFound => return error.LockConflict,
            else => return err,
        };
        defer existing.deinit();
        var lock = try local_state.parseLock(self.allocator, existing.bytes);
        defer lock.deinit();
        if (!lock.metadata.isExpired(now_millis)) return error.LockConflict;
        const content = try local_state.lockJsonAlloc(self.allocator, metadata);
        defer self.allocator.free(content);
        var created = self.objects.put(key, content, .{ .generation = existing.generation }) catch |err| switch (err) {
            error.Conflict => return error.LockConflict,
            else => return err,
        };
        created.deinit();
    }

    fn observeIfUnknown(self: *Remote, key: []const u8) !void {
        if (self.hasObservedGeneration(key)) return;
        var object = self.objects.get(key) catch |err| switch (err) {
            error.NotFound => {
                self.clearGeneration(key);
                return;
            },
            else => return err,
        };
        defer object.deinit();
        try self.setGeneration(key, object.generation);
    }

    fn putObserved(self: *Remote, key: []const u8, content: []const u8, comptime conflict_error: anyerror) !void {
        const observed = try self.observedGenerationAlloc(key);
        defer if (observed) |generation| self.allocator.free(generation);
        const precondition: Precondition = if (observed) |generation| .{ .generation = generation } else .absent;
        var result = self.objects.put(key, content, precondition) catch |err| switch (err) {
            error.Conflict => return conflict_error,
            else => return err,
        };
        defer result.deinit();
        try self.setGeneration(key, result.generation);
    }

    fn keyAlloc(self: *Remote, stack: []const u8, stage: []const u8, file: []const u8) ![]u8 {
        try validateSegment(stack);
        try validateSegment(stage);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}/{s}", .{ self.prefix, stack, stage, file });
    }

    fn hasObservedGeneration(self: *Remote, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.generations.contains(key);
    }

    fn observedGenerationAlloc(self: *Remote, key: []const u8) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const generation = self.generations.get(key) orelse return null;
        return try self.allocator.dupe(u8, generation);
    }

    fn setGeneration(self: *Remote, key: []const u8, generation: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const owned_generation = try self.allocator.dupe(u8, generation);
        errdefer self.allocator.free(owned_generation);
        if (self.generations.getPtr(key)) |existing| {
            self.allocator.free(existing.*);
            existing.* = owned_generation;
            return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.generations.put(owned_key, owned_generation);
    }

    fn clearGeneration(self: *Remote, key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.generations.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }
    }
};

pub fn migrateLocalToBackend(
    allocator: std.mem.Allocator,
    local: local_state.Store,
    target: Store,
    stack: []const u8,
    stage: []const u8,
) !void {
    if (target.loadResources(stack, stage)) |loaded| {
        var existing = loaded;
        existing.deinit();
        return error.TargetStateExists;
    } else |err| if (err != error.MissingStateFile) return err;
    if (target.loadOutputs(stack, stage)) |loaded| {
        var existing = loaded;
        existing.deinit();
        return error.TargetStateExists;
    } else |err| if (err != error.MissingStateFile) return err;

    var source = try local.loadResources(stack, stage);
    defer source.deinit();
    const before = source.store.metadata();
    try target.saveResources(stack, stage, &source.store);

    if (local.loadOutputs(stack, stage)) |loaded| {
        var outputs = loaded;
        defer outputs.deinit();
        const entries = try allocator.alloc(stack_registry.OutputEntry, outputs.items.len);
        defer allocator.free(entries);
        for (outputs.items, 0..) |entry, index| entries[index] = .{
            .name = entry.name,
            .value = entry.value,
            .secret = entry.secret,
        };
        try target.saveOutputs(stack, stage, entries);
    } else |err| if (err != error.MissingStateFile) return err;

    var verified = try target.loadResources(stack, stage);
    defer verified.deinit();
    const after = verified.store.metadata();
    if (before.serial != after.serial or !std.mem.eql(u8, &before.lineage_hash, &after.lineage_hash)) {
        return error.MigrationVerificationFailed;
    }
}

fn storeFor(pointer: anytype, comptime T: type) Store {
    return .{
        .ptr = pointer,
        .saveResourcesFn = T.saveResources,
        .loadResourcesFn = T.loadResources,
        .loadResourcesOrEmptyFn = T.loadResourcesOrEmpty,
        .saveOutputsFn = T.saveOutputs,
        .loadOutputsFn = T.loadOutputs,
        .acquireLockFn = T.acquireLock,
        .inspectLockFn = T.inspectLock,
        .hasLockFn = T.hasLock,
        .renewLockFn = T.renewLock,
        .releaseLockFn = T.releaseLock,
        .forceUnlockFn = T.forceUnlock,
    };
}

fn as(comptime T: type, raw: *anyopaque) *T {
    return @ptrCast(@alignCast(raw));
}

fn validatePrefix(prefix: []const u8) !void {
    if (prefix.len == 0 or prefix[0] == '/' or prefix[prefix.len - 1] == '/') return error.InvalidPrefix;
    var segments = std.mem.splitScalar(u8, prefix, '/');
    while (segments.next()) |segment| try validateSegment(segment);
}

fn validateSegment(segment: []const u8) !void {
    if (segment.len == 0 or segment.len > 128 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
        return error.InvalidStatePath;
    }
    for (segment) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_' and character != '.') {
            return error.InvalidStatePath;
        }
    }
}
