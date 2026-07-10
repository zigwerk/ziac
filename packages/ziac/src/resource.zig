const std = @import("std");
const value_mod = @import("value.zig");

pub const ResourceGraphError = error{
    DuplicateResource,
    DuplicateField,
    MissingResource,
    DependencyCycle,
    OutOfMemory,
};

pub const ProviderId = enum {
    local,
    gcp,
    cockroach,
};

pub const Lifecycle = struct {
    protect: bool = false,
    retain_on_delete: bool = false,
    replace_before_delete: bool = false,
    ignore_changes: []const []const u8 = &.{},
    operation_timeout_millis: u64 = 15 * 60 * 1000,
};

pub const ResourceNode = struct {
    id: []const u8,
    provider: ProviderId = .local,
    type_name: []const u8,
    schema_version: u32 = 1,
    logical_id: []const u8,
    inputs: value_mod.Value = .{ .object = &.{} },
    inputs_hash: [32]u8 = [_]u8{0} ** 32,
    lifecycle: Lifecycle = .{},

    pub fn initOwned(
        allocator: std.mem.Allocator,
        source: ResourceNode,
    ) ResourceGraphError!ResourceNode {
        const id = try allocator.dupe(u8, source.id);
        errdefer allocator.free(id);
        const type_name = try allocator.dupe(u8, source.type_name);
        errdefer allocator.free(type_name);
        const logical_id = try allocator.dupe(u8, source.logical_id);
        errdefer allocator.free(logical_id);
        var inputs = value_mod.Value.initOwned(allocator, source.inputs) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer inputs.deinit(allocator);
        const lifecycle = try cloneLifecycle(allocator, source.lifecycle);
        errdefer freeLifecycle(allocator, lifecycle);
        const inputs_hash = inputs.sha256(allocator) catch |err| switch (err) {
            error.DuplicateField => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };

        return .{
            .id = id,
            .provider = source.provider,
            .type_name = type_name,
            .schema_version = source.schema_version,
            .logical_id = logical_id,
            .inputs = inputs,
            .inputs_hash = inputs_hash,
            .lifecycle = lifecycle,
        };
    }

    pub fn deinit(self: *ResourceNode, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.type_name);
        allocator.free(self.logical_id);
        self.inputs.deinit(allocator);
        freeLifecycle(allocator, self.lifecycle);
        self.* = undefined;
    }
};

pub const DependencyEdge = struct {
    from: []const u8,
    to: []const u8,
};

pub const ResourceGraph = struct {
    allocator: std.mem.Allocator,
    resources: std.ArrayList(ResourceNode),
    dependencies: std.ArrayList(DependencyEdge),

    pub fn init(allocator: std.mem.Allocator) ResourceGraph {
        return .{
            .allocator = allocator,
            .resources = std.ArrayList(ResourceNode).empty,
            .dependencies = std.ArrayList(DependencyEdge).empty,
        };
    }

    pub fn deinit(self: *ResourceGraph) void {
        self.dependencies.deinit(self.allocator);
        for (self.resources.items) |*node| node.deinit(self.allocator);
        self.resources.deinit(self.allocator);
    }

    pub fn addResource(self: *ResourceGraph, node: ResourceNode) ResourceGraphError!void {
        if (self.indexOf(node.id) != null) return error.DuplicateResource;
        var owned = try ResourceNode.initOwned(self.allocator, node);
        self.resources.append(self.allocator, owned) catch |err| {
            owned.deinit(self.allocator);
            return err;
        };
        const dependency_count = self.dependencies.items.len;
        errdefer {
            while (self.dependencies.items.len > dependency_count) _ = self.dependencies.pop();
            var removed = self.resources.pop().?;
            removed.deinit(self.allocator);
        }
        const stored = self.resources.items[self.resources.items.len - 1];
        try self.bindInputReferences(stored.id, stored.inputs);
    }

    pub fn addDependency(self: *ResourceGraph, from: []const u8, to: []const u8) ResourceGraphError!void {
        const from_index = self.indexOf(from) orelse return error.MissingResource;
        const to_index = self.indexOf(to) orelse return error.MissingResource;
        for (self.dependencies.items) |edge| {
            if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return;
        }
        try self.dependencies.append(self.allocator, .{
            .from = self.resources.items[from_index].id,
            .to = self.resources.items[to_index].id,
        });
    }

    pub fn bindOutput(self: *ResourceGraph, consumer_id: []const u8, typed_output: anytype) ResourceGraphError!void {
        const reference = typed_output.referenceOrNull() orelse return;
        try self.addDependency(consumer_id, reference.resource_id);
    }

    fn bindInputReferences(
        self: *ResourceGraph,
        consumer_id: []const u8,
        input: value_mod.Value,
    ) ResourceGraphError!void {
        switch (input) {
            .list => |items| for (items) |item| try self.bindInputReferences(consumer_id, item),
            .object => |fields| for (fields) |field| try self.bindInputReferences(consumer_id, field.value),
            .output_ref => |reference| try self.addDependency(consumer_id, reference.resource_id),
            .string, .integer, .boolean, .secret_ref, .unknown_reason => {},
        }
    }

    pub fn validateAcyclic(self: *const ResourceGraph) ResourceGraphError!void {
        for (self.resources.items) |node| {
            if (try self.hasPath(node.id, node.id, 0)) return error.DependencyCycle;
        }
    }

    fn indexOf(self: *const ResourceGraph, id: []const u8) ?usize {
        for (self.resources.items, 0..) |node, index| {
            if (std.mem.eql(u8, node.id, id)) return index;
        }
        return null;
    }

    fn hasPath(self: *const ResourceGraph, start: []const u8, target: []const u8, depth: usize) ResourceGraphError!bool {
        if (depth > self.resources.items.len) return error.DependencyCycle;
        for (self.dependencies.items) |edge| {
            if (!std.mem.eql(u8, edge.from, start)) continue;
            if (std.mem.eql(u8, edge.to, target)) return true;
            if (try self.hasPath(edge.to, target, depth + 1)) return true;
        }
        return false;
    }
};

fn cloneLifecycle(allocator: std.mem.Allocator, source: Lifecycle) ResourceGraphError!Lifecycle {
    const ignore_changes = try allocator.alloc([]const u8, source.ignore_changes.len);
    errdefer allocator.free(ignore_changes);

    var initialized: usize = 0;
    errdefer {
        for (ignore_changes[0..initialized]) |field| allocator.free(field);
    }
    for (source.ignore_changes, 0..) |field, index| {
        ignore_changes[index] = try allocator.dupe(u8, field);
        initialized += 1;
    }

    return .{
        .protect = source.protect,
        .retain_on_delete = source.retain_on_delete,
        .replace_before_delete = source.replace_before_delete,
        .ignore_changes = ignore_changes,
        .operation_timeout_millis = source.operation_timeout_millis,
    };
}

fn freeLifecycle(allocator: std.mem.Allocator, lifecycle: Lifecycle) void {
    for (lifecycle.ignore_changes) |field| allocator.free(field);
    allocator.free(lifecycle.ignore_changes);
}
