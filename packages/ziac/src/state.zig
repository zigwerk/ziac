const std = @import("std");
const fx = @import("zigeffect_std").fx;
const resource = @import("resource.zig");
const value = @import("value.zig");

pub const StateError = error{
    DuplicateField,
    MissingRecord,
    OutOfMemory,
};

pub const ResourceStatus = enum {
    planned,
    creating,
    created,
    updating,
    updated,
    replacing,
    deleting,
    deleted,
    failed,
    tainted,
    adopted,
};

pub const StateOutput = struct {
    name: []const u8,
    value: value.Value,
};

pub const StateRecord = struct {
    resource_id: []const u8,
    provider: resource.ProviderId = .local,
    type_name: []const u8,
    schema_version: u32 = 1,
    logical_id: []const u8,
    physical_id: ?[]const u8 = null,
    desired_hash: []const u8,
    observed_hash: ?[]const u8 = null,
    dependencies: []const []const u8 = &.{},
    outputs: []const StateOutput = &.{},
    protect: bool = false,
    retain_on_delete: bool = false,
    status: ResourceStatus,
    operation_handle: ?[]const u8 = null,

    pub fn initOwned(allocator: std.mem.Allocator, source: StateRecord) StateError!StateRecord {
        const resource_id = try allocator.dupe(u8, source.resource_id);
        errdefer allocator.free(resource_id);
        const type_name = try allocator.dupe(u8, source.type_name);
        errdefer allocator.free(type_name);
        const logical_id = try allocator.dupe(u8, source.logical_id);
        errdefer allocator.free(logical_id);
        const physical_id = try cloneOptionalString(allocator, source.physical_id);
        errdefer freeOptionalString(allocator, physical_id);
        const desired_hash = try allocator.dupe(u8, source.desired_hash);
        errdefer allocator.free(desired_hash);
        const observed_hash = try cloneOptionalString(allocator, source.observed_hash);
        errdefer freeOptionalString(allocator, observed_hash);
        const dependencies = try cloneStrings(allocator, source.dependencies);
        errdefer freeStrings(allocator, dependencies);
        const outputs = try cloneOutputs(allocator, source.outputs);
        errdefer freeOutputs(allocator, outputs);
        const operation_handle = try cloneOptionalString(allocator, source.operation_handle);
        errdefer freeOptionalString(allocator, operation_handle);

        return .{
            .resource_id = resource_id,
            .provider = source.provider,
            .type_name = type_name,
            .schema_version = source.schema_version,
            .logical_id = logical_id,
            .physical_id = physical_id,
            .desired_hash = desired_hash,
            .observed_hash = observed_hash,
            .dependencies = dependencies,
            .outputs = outputs,
            .protect = source.protect,
            .retain_on_delete = source.retain_on_delete,
            .status = source.status,
            .operation_handle = operation_handle,
        };
    }

    pub fn deinit(self: *StateRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.resource_id);
        self.deinitExceptResourceId(allocator);
        self.* = undefined;
    }

    fn deinitExceptResourceId(self: *StateRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.type_name);
        allocator.free(self.logical_id);
        freeOptionalString(allocator, self.physical_id);
        allocator.free(self.desired_hash);
        freeOptionalString(allocator, self.observed_hash);
        freeStrings(allocator, self.dependencies);
        freeOutputs(allocator, self.outputs);
        freeOptionalString(allocator, self.operation_handle);
    }
};

pub const StateSnapshot = struct {
    allocator: std.mem.Allocator,
    serial: u64,
    records: []StateRecord,

    pub fn deinit(self: *StateSnapshot) void {
        for (self.records) |*record| record.deinit(self.allocator);
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

pub const InMemoryStateStore = struct {
    allocator: std.mem.Allocator,
    records: std.StringHashMap(StateRecord),
    serial: u64 = 0,
    mutex: fx.SpinLock = .{},

    pub fn init(allocator: std.mem.Allocator) InMemoryStateStore {
        return .{
            .allocator = allocator,
            .records = std.StringHashMap(StateRecord).init(allocator),
        };
    }

    pub fn deinit(self: *InMemoryStateStore) void {
        var iterator = self.records.valueIterator();
        while (iterator.next()) |record| record.deinit(self.allocator);
        self.records.deinit();
        self.* = undefined;
    }

    pub fn put(self: *InMemoryStateStore, record: StateRecord) StateError!void {
        var owned = try StateRecord.initOwned(self.allocator, record);
        errdefer owned.deinit(self.allocator);
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.records.getPtr(record.resource_id)) |existing| {
            const stable_resource_id = existing.resource_id;
            self.allocator.free(owned.resource_id);
            owned.resource_id = stable_resource_id;
            existing.deinitExceptResourceId(self.allocator);
            existing.* = owned;
            self.serial += 1;
            return;
        }

        try self.records.put(owned.resource_id, owned);
        self.serial += 1;
    }

    pub fn get(self: *InMemoryStateStore, resource_id: []const u8) ?StateRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.records.get(resource_id);
    }

    pub fn getOwned(
        self: *InMemoryStateStore,
        allocator: std.mem.Allocator,
        resource_id: []const u8,
    ) StateError!?StateRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        const record = self.records.get(resource_id) orelse return null;
        return try StateRecord.initOwned(allocator, record);
    }

    pub fn serialValue(self: *InMemoryStateStore) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.serial;
    }

    pub fn snapshotAlloc(
        self: *InMemoryStateStore,
        allocator: std.mem.Allocator,
    ) StateError!StateSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        var records = std.ArrayList(StateRecord).empty;
        errdefer {
            for (records.items) |*record| record.deinit(allocator);
            records.deinit(allocator);
        }

        var iterator = self.records.valueIterator();
        while (iterator.next()) |record| {
            var owned = try StateRecord.initOwned(allocator, record.*);
            errdefer owned.deinit(allocator);
            try records.append(allocator, owned);
        }

        const owned_records = try records.toOwnedSlice(allocator);
        std.mem.sort(StateRecord, owned_records, {}, lessThanRecordId);
        return .{
            .allocator = allocator,
            .serial = self.serial,
            .records = owned_records,
        };
    }

    pub fn markFailed(self: *InMemoryStateStore, resource_id: []const u8) StateError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const record = self.records.getPtr(resource_id) orelse return error.MissingRecord;
        record.status = .failed;
        self.serial += 1;
    }

    pub fn recordsAlloc(self: *InMemoryStateStore, allocator: std.mem.Allocator) StateError![]StateRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        var records = std.ArrayList(StateRecord).empty;
        errdefer records.deinit(allocator);

        var iterator = self.records.valueIterator();
        while (iterator.next()) |record| {
            try records.append(allocator, record.*);
        }

        const owned = try records.toOwnedSlice(allocator);
        std.mem.sort(StateRecord, owned, {}, lessThanRecordId);
        return owned;
    }
};

fn cloneOptionalString(
    allocator: std.mem.Allocator,
    source: ?[]const u8,
) std.mem.Allocator.Error!?[]const u8 {
    return if (source) |inner| try allocator.dupe(u8, inner) else null;
}

fn freeOptionalString(allocator: std.mem.Allocator, source: ?[]const u8) void {
    if (source) |inner| allocator.free(inner);
}

fn cloneStrings(
    allocator: std.mem.Allocator,
    source: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const strings = try allocator.alloc([]const u8, source.len);
    errdefer allocator.free(strings);

    var initialized: usize = 0;
    errdefer {
        for (strings[0..initialized]) |inner| allocator.free(inner);
    }
    for (source, 0..) |inner, index| {
        strings[index] = try allocator.dupe(u8, inner);
        initialized += 1;
    }
    return strings;
}

fn freeStrings(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |inner| allocator.free(inner);
    allocator.free(strings);
}

fn cloneOutputs(
    allocator: std.mem.Allocator,
    source: []const StateOutput,
) StateError![]const StateOutput {
    const outputs = try allocator.alloc(StateOutput, source.len);
    errdefer allocator.free(outputs);

    var initialized: usize = 0;
    errdefer {
        for (outputs[0..initialized]) |*output| {
            allocator.free(output.name);
            output.value.deinit(allocator);
        }
    }
    for (source, 0..) |output, index| {
        const name = try allocator.dupe(u8, output.name);
        errdefer allocator.free(name);
        var owned_value = value.Value.initOwned(allocator, output.value) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer owned_value.deinit(allocator);
        outputs[index] = .{ .name = name, .value = owned_value };
        initialized += 1;
    }
    return outputs;
}

fn freeOutputs(allocator: std.mem.Allocator, outputs: []const StateOutput) void {
    const mutable_outputs: []StateOutput = @constCast(outputs);
    for (mutable_outputs) |*output| {
        allocator.free(output.name);
        output.value.deinit(allocator);
    }
    allocator.free(outputs);
}

fn lessThanRecordId(_: void, left: StateRecord, right: StateRecord) bool {
    return std.mem.lessThan(u8, left.resource_id, right.resource_id);
}
