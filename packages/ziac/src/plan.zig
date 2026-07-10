const std = @import("std");
const provider_mod = @import("provider.zig");
const resource = @import("resource.zig");
const state = @import("state.zig");

pub const PlanError = error{
    DependencyCycle,
    ProtectedResource,
    OutOfMemory,
};

pub const BuildPlanError = PlanError || state.StateError;
pub const RefreshedPlanError = BuildPlanError || provider_mod.ProviderError;

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
    dependencies: []const []const u8 = &.{},
    reasons: []const []const u8 = &.{},
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    operations: []PlanOperation,

    pub fn deinit(self: *Plan) void {
        freeOperationMetadata(self.allocator, self.operations);
        self.allocator.free(self.operations);
        self.* = undefined;
    }
};

pub fn buildPlan(
    allocator: std.mem.Allocator,
    graph: *const resource.ResourceGraph,
    store: *state.InMemoryStateStore,
) BuildPlanError!Plan {
    try validateGraph(graph);
    var operations = std.ArrayList(PlanOperation).empty;
    errdefer deinitOperationList(allocator, &operations);

    for (graph.resources.items) |node| {
        const existing = store.get(node.id);
        if (existing == null or existing.?.status == .deleted) {
            try appendGraphOperation(allocator, &operations, graph, .create, node, &.{"resource is not in state"});
            continue;
        }
        if (recoveryKind(existing.?)) |kind| {
            if (kind == .replace and node.lifecycle.protect) return error.ProtectedResource;
            try appendGraphOperation(
                allocator,
                &operations,
                graph,
                kind,
                node,
                &.{"resource has incomplete state"},
            );
            continue;
        }

        const desired_hash = std.fmt.bytesToHex(node.inputs_hash, .lower);
        if (std.mem.eql(u8, existing.?.desired_hash, desired_hash[0..])) {
            try appendGraphOperation(allocator, &operations, graph, .noop, node, &.{});
        } else {
            try appendGraphOperation(allocator, &operations, graph, .update, node, &.{"desired inputs changed"});
        }
    }
    try appendRemovedResources(allocator, &operations, graph, store);
    return finishPlan(allocator, &operations);
}

fn recoveryKind(record: state.StateRecord) ?OperationKind {
    return switch (record.status) {
        .planned, .creating => .create,
        .updating => .update,
        .replacing, .deleting, .tainted => .replace,
        .failed => if (record.physical_id == null) .create else .update,
        .created, .updated, .deleted, .adopted => null,
    };
}

pub fn buildRefreshedPlan(
    allocator: std.mem.Allocator,
    graph: *const resource.ResourceGraph,
    store: *state.InMemoryStateStore,
    providers: provider_mod.ProviderRegistry,
) RefreshedPlanError!Plan {
    try validateGraph(graph);
    var operations = std.ArrayList(PlanOperation).empty;
    errdefer deinitOperationList(allocator, &operations);

    for (graph.resources.items) |node| {
        const provider = try providers.get(node.provider);
        var read = try provider.read(allocator, node);
        defer read.deinit();
        switch (read) {
            .absent => try appendGraphOperation(
                allocator,
                &operations,
                graph,
                .create,
                node,
                &.{"remote resource is absent"},
            ),
            .present => |*observed| {
                var diff = try provider.diff(allocator, node, observed);
                defer diff.deinit();
                const kind: OperationKind = switch (diff.kind) {
                    .noop => .noop,
                    .update => .update,
                    .replace => .replace,
                };
                if (kind == .replace and node.lifecycle.protect) return error.ProtectedResource;
                try appendGraphOperation(allocator, &operations, graph, kind, node, diff.reasons);
            },
        }
    }
    try appendRemovedResources(allocator, &operations, graph, store);
    return finishPlan(allocator, &operations);
}

pub fn buildDestroyPlan(
    allocator: std.mem.Allocator,
    store: *state.InMemoryStateStore,
) BuildPlanError!Plan {
    var operations = std.ArrayList(PlanOperation).empty;
    errdefer deinitOperationList(allocator, &operations);

    const records = try store.recordsAlloc(allocator);
    defer allocator.free(records);
    for (records) |record| {
        if (record.status == .deleted) continue;
        if (record.protect) return error.ProtectedResource;
        try appendOperation(
            allocator,
            &operations,
            .delete,
            nodeFromRecord(record),
            record.dependencies,
            &.{"destroy requested"},
        );
    }
    return finishPlan(allocator, &operations);
}

fn validateGraph(graph: *const resource.ResourceGraph) PlanError!void {
    graph.validateAcyclic() catch |err| switch (err) {
        error.DependencyCycle => return error.DependencyCycle,
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateResource, error.DuplicateField, error.MissingResource => unreachable,
    };
}

fn appendRemovedResources(
    allocator: std.mem.Allocator,
    operations: *std.ArrayList(PlanOperation),
    graph: *const resource.ResourceGraph,
    store: *state.InMemoryStateStore,
) BuildPlanError!void {
    const records = try store.recordsAlloc(allocator);
    defer allocator.free(records);
    for (records) |record| {
        if (record.status == .deleted or graphContains(graph, record.resource_id)) continue;
        if (record.protect) return error.ProtectedResource;
        try appendOperation(
            allocator,
            operations,
            .delete,
            nodeFromRecord(record),
            record.dependencies,
            &.{"resource was removed from desired graph"},
        );
    }
}

fn graphContains(graph: *const resource.ResourceGraph, id: []const u8) bool {
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.id, id)) return true;
    }
    return false;
}

fn nodeFromRecord(record: state.StateRecord) resource.ResourceNode {
    return .{
        .id = record.resource_id,
        .provider = record.provider,
        .type_name = record.type_name,
        .schema_version = record.schema_version,
        .logical_id = record.logical_id,
        .lifecycle = .{
            .protect = record.protect,
            .retain_on_delete = record.retain_on_delete,
        },
    };
}

fn appendOperation(
    allocator: std.mem.Allocator,
    operations: *std.ArrayList(PlanOperation),
    kind: OperationKind,
    node: resource.ResourceNode,
    dependencies: []const []const u8,
    reasons: []const []const u8,
) std.mem.Allocator.Error!void {
    const owned_dependencies = try cloneStrings(allocator, dependencies);
    errdefer freeStrings(allocator, owned_dependencies);
    const owned_reasons = try cloneStrings(allocator, reasons);
    errdefer freeStrings(allocator, owned_reasons);
    try operations.append(allocator, .{
        .kind = kind,
        .resource = node,
        .dependencies = owned_dependencies,
        .reasons = owned_reasons,
    });
}

fn appendGraphOperation(
    allocator: std.mem.Allocator,
    operations: *std.ArrayList(PlanOperation),
    graph: *const resource.ResourceGraph,
    kind: OperationKind,
    node: resource.ResourceNode,
    reasons: []const []const u8,
) std.mem.Allocator.Error!void {
    var dependencies = std.ArrayList([]const u8).empty;
    defer dependencies.deinit(allocator);
    for (graph.dependencies.items) |edge| {
        if (std.mem.eql(u8, edge.from, node.id)) try dependencies.append(allocator, edge.to);
    }
    std.mem.sort([]const u8, dependencies.items, {}, lessThanString);
    try appendOperation(allocator, operations, kind, node, dependencies.items, reasons);
}

fn finishPlan(
    allocator: std.mem.Allocator,
    operations: *std.ArrayList(PlanOperation),
) std.mem.Allocator.Error!Plan {
    return .{
        .allocator = allocator,
        .operations = try operations.toOwnedSlice(allocator),
    };
}

fn deinitOperationList(
    allocator: std.mem.Allocator,
    operations: *std.ArrayList(PlanOperation),
) void {
    freeOperationMetadata(allocator, operations.items);
    operations.deinit(allocator);
}

fn freeOperationMetadata(allocator: std.mem.Allocator, operations: []const PlanOperation) void {
    for (operations) |operation| {
        freeStrings(allocator, operation.dependencies);
        freeStrings(allocator, operation.reasons);
    }
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

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
