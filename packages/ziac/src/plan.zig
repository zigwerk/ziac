const std = @import("std");
const resource = @import("resource.zig");
const state = @import("state.zig");

pub const PlanError = error{
    DependencyCycle,
    OutOfMemory,
};

pub const OperationKind = enum {
    create,
    update,
    replace,
    delete,
    read,
    noop,
};

pub const PlanOperation = struct {
    kind: OperationKind,
    resource: resource.ResourceNode,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    operations: []PlanOperation,

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.operations);
    }
};

pub fn buildPlan(
    allocator: std.mem.Allocator,
    graph: *const resource.ResourceGraph,
    store: *state.InMemoryStateStore,
) PlanError!Plan {
    graph.validateAcyclic() catch |err| switch (err) {
        error.DependencyCycle => return error.DependencyCycle,
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateResource, error.MissingResource => unreachable,
    };

    var operations = std.ArrayList(PlanOperation).empty;
    errdefer operations.deinit(allocator);

    for (graph.resources.items) |node| {
        const existing = store.get(node.id);
        const kind: OperationKind = if (existing == null) .create else .noop;
        try operations.append(allocator, .{ .kind = kind, .resource = node });
    }

    return .{
        .allocator = allocator,
        .operations = try operations.toOwnedSlice(allocator),
    };
}
