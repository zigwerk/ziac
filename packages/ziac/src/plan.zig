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

pub const PlanPreconditions = struct {
    lineage_hash: [32]u8,
    state_serial: u64,
    desired_graph_digest: [32]u8,
    operations_digest: [32]u8,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    operations: []PlanOperation,
    preconditions: PlanPreconditions,

    pub fn deinit(self: *Plan) void {
        freeOperationMetadata(self.allocator, self.operations);
        self.allocator.free(self.operations);
        self.* = undefined;
    }
};

pub fn hasDestructiveOperations(operations: []const PlanOperation) bool {
    for (operations) |operation| switch (operation.kind) {
        .delete, .replace => return true,
        .create, .update, .read, .noop => {},
    };
    return false;
}

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
    return finishPlan(allocator, &operations, store.metadata(), try desiredGraphDigestAlloc(allocator, graph));
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
        var context = provider_mod.OperationContext.init(allocator);
        context.state = store;
        if (store.get(node.id)) |existing| {
            context.physical_id = existing.physical_id;
            context.operation_handle = existing.operation_handle;
        }
        var read = try provider.readWithContext(&context, node);
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
                var diff = try provider.diffWithContext(&context, node, observed);
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
    return finishPlan(allocator, &operations, store.metadata(), try desiredGraphDigestAlloc(allocator, graph));
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
    return finishPlan(allocator, &operations, store.metadata(), emptyDesiredGraphDigest());
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
    metadata: state.StateMetadata,
    desired_graph_digest: [32]u8,
) std.mem.Allocator.Error!Plan {
    const owned_operations = try operations.toOwnedSlice(allocator);
    errdefer {
        freeOperationMetadata(allocator, owned_operations);
        allocator.free(owned_operations);
    }
    return .{
        .allocator = allocator,
        .operations = owned_operations,
        .preconditions = .{
            .lineage_hash = metadata.lineage_hash,
            .state_serial = metadata.serial,
            .desired_graph_digest = desired_graph_digest,
            .operations_digest = try operationsDigestAlloc(allocator, owned_operations),
        },
    };
}

pub fn operationsDigestAlloc(
    allocator: std.mem.Allocator,
    operations: []const PlanOperation,
) std.mem.Allocator.Error![32]u8 {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try appendFramed(&bytes, allocator, "ziac.plan.operations.v2");
    for (operations) |operation| {
        try appendFramed(&bytes, allocator, @tagName(operation.kind));
        try appendNodeDigest(&bytes, allocator, operation.resource);
        for (operation.dependencies) |dependency| try appendFramed(&bytes, allocator, dependency);
        try bytes.append(allocator, 0xff);
        for (operation.reasons) |reason| try appendFramed(&bytes, allocator, reason);
        try bytes.append(allocator, 0xfe);
    }
    return hashBytes(bytes.items);
}

pub fn desiredGraphDigestAlloc(
    allocator: std.mem.Allocator,
    graph: *const resource.ResourceGraph,
) std.mem.Allocator.Error![32]u8 {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try appendFramed(&bytes, allocator, "ziac.desired.graph.v2");

    const resource_indexes = try allocator.alloc(usize, graph.resources.items.len);
    defer allocator.free(resource_indexes);
    for (resource_indexes, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, resource_indexes, graph, lessThanResourceIndex);
    for (resource_indexes) |index| {
        try appendNodeDigest(&bytes, allocator, graph.resources.items[index]);
    }

    const edges = try allocator.dupe(resource.DependencyEdge, graph.dependencies.items);
    defer allocator.free(edges);
    std.mem.sort(resource.DependencyEdge, edges, {}, lessThanEdge);
    for (edges) |edge| {
        try appendFramed(&bytes, allocator, edge.from);
        try appendFramed(&bytes, allocator, edge.to);
    }
    return hashBytes(bytes.items);
}

pub fn emptyDesiredGraphDigest() [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("21:ziac.desired.graph.v2", &digest, .{});
    return digest;
}

fn appendNodeDigest(
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) std.mem.Allocator.Error!void {
    try appendFramed(bytes, allocator, node.id);
    try appendFramed(bytes, allocator, @tagName(node.provider));
    try appendFramed(bytes, allocator, node.type_name);
    try bytes.print(allocator, "{d}:", .{node.schema_version});
    try appendFramed(bytes, allocator, node.logical_id);
    const canonical_inputs: ?[]const u8 = node.inputs.canonicalJsonAlloc(allocator) catch |err| switch (err) {
        error.DuplicateField => null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer if (canonical_inputs) |inputs| allocator.free(inputs);
    try appendFramed(bytes, allocator, canonical_inputs orelse "invalid:duplicate-input-field");
    try bytes.appendSlice(allocator, &node.inputs_hash);
    try bytes.append(allocator, @intFromBool(node.lifecycle.protect));
    try bytes.append(allocator, @intFromBool(node.lifecycle.retain_on_delete));
    try bytes.append(allocator, @intFromBool(node.lifecycle.replace_before_delete));
    try bytes.print(allocator, "{d}:", .{node.lifecycle.operation_timeout_millis});
    const ignored = try allocator.dupe([]const u8, node.lifecycle.ignore_changes);
    defer allocator.free(ignored);
    std.mem.sort([]const u8, ignored, {}, lessThanString);
    for (ignored) |field| try appendFramed(bytes, allocator, field);
    try bytes.append(allocator, 0xfd);
}

fn appendFramed(
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) std.mem.Allocator.Error!void {
    try bytes.print(allocator, "{d}:", .{value.len});
    try bytes.appendSlice(allocator, value);
}

fn hashBytes(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn lessThanResourceIndex(
    graph: *const resource.ResourceGraph,
    left: usize,
    right: usize,
) bool {
    return std.mem.lessThan(u8, graph.resources.items[left].id, graph.resources.items[right].id);
}

fn lessThanEdge(_: void, left: resource.DependencyEdge, right: resource.DependencyEdge) bool {
    const from_order = std.mem.order(u8, left.from, right.from);
    if (from_order != .eq) return from_order == .lt;
    return std.mem.lessThan(u8, left.to, right.to);
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
