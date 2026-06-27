const std = @import("std");

pub const StateError = error{
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

pub const StateRecord = struct {
    resource_id: []const u8,
    type_name: []const u8,
    logical_id: []const u8,
    inputs_hash: []const u8,
    status: ResourceStatus,
};

pub const InMemoryStateStore = struct {
    allocator: std.mem.Allocator,
    records: std.StringHashMap(StateRecord),

    pub fn init(allocator: std.mem.Allocator) InMemoryStateStore {
        return .{
            .allocator = allocator,
            .records = std.StringHashMap(StateRecord).init(allocator),
        };
    }

    pub fn deinit(self: *InMemoryStateStore) void {
        self.records.deinit();
    }

    pub fn put(self: *InMemoryStateStore, record: StateRecord) StateError!void {
        try self.records.put(record.resource_id, record);
    }

    pub fn get(self: *InMemoryStateStore, resource_id: []const u8) ?StateRecord {
        return self.records.get(resource_id);
    }

    pub fn markFailed(self: *InMemoryStateStore, resource_id: []const u8) StateError!void {
        var record = self.records.get(resource_id) orelse return error.MissingRecord;
        record.status = .failed;
        try self.records.put(resource_id, record);
    }
};
