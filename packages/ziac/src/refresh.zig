const std = @import("std");
const apply_mod = @import("apply.zig");
const checkpoint_mod = @import("checkpoint.zig");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const resource_mod = @import("resource.zig");
const state_mod = @import("state.zig");

pub const RefreshError = apply_mod.ApplyError || provider_mod.ProviderError || state_mod.StateError;

pub fn refreshGraph(
    allocator: std.mem.Allocator,
    graph: *const resource_mod.ResourceGraph,
    store: *state_mod.InMemoryStateStore,
    providers: provider_mod.ProviderRegistry,
    checkpoint: ?checkpoint_mod.Checkpoint,
) RefreshError!void {
    for (graph.resources.items) |node| {
        const dependencies = try dependenciesAlloc(allocator, graph, node.id);
        defer allocator.free(dependencies);
        const operation = plan_mod.PlanOperation{
            .kind = .read,
            .resource = node,
            .dependencies = dependencies,
        };
        const provider = try providers.get(node.provider);
        var context = provider_mod.OperationContext.init(allocator);
        if (store.get(node.id)) |existing| context.physical_id = existing.physical_id;
        var read = try provider.readWithContext(&context, node);
        defer read.deinit();
        switch (read) {
            .absent => try markAbsent(allocator, store, node.id, checkpoint),
            .present => |observed| try apply_mod.adoptObserved(store, operation, observed, checkpoint),
        }
    }
}

fn dependenciesAlloc(
    allocator: std.mem.Allocator,
    graph: *const resource_mod.ResourceGraph,
    resource_id: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var dependencies = std.ArrayList([]const u8).empty;
    errdefer dependencies.deinit(allocator);
    for (graph.dependencies.items) |edge| {
        if (std.mem.eql(u8, edge.from, resource_id)) try dependencies.append(allocator, edge.to);
    }
    std.mem.sort([]const u8, dependencies.items, {}, lessThanString);
    return dependencies.toOwnedSlice(allocator);
}

fn markAbsent(
    allocator: std.mem.Allocator,
    store: *state_mod.InMemoryStateStore,
    resource_id: []const u8,
    checkpoint: ?checkpoint_mod.Checkpoint,
) RefreshError!void {
    var existing = (try store.getOwned(allocator, resource_id)) orelse return;
    defer existing.deinit(allocator);
    existing.status = .tainted;
    try store.put(existing);
    if (checkpoint) |target| try target.save(store);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
