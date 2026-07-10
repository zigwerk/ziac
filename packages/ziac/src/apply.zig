const std = @import("std");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const resource_mod = @import("resource.zig");
const state_mod = @import("state.zig");

pub const ApplyError = provider_mod.ProviderError || state_mod.StateError;

pub fn applyPlan(
    allocator: std.mem.Allocator,
    planned: *const plan_mod.Plan,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
) ApplyError!void {
    for (planned.operations) |operation| {
        switch (operation.kind) {
            .create => try applyCreate(allocator, store, provider, operation.resource, .created),
            .update => try applyUpdate(allocator, store, provider, operation.resource),
            .replace => try applyReplace(allocator, store, provider, operation.resource),
            .delete => try applyDelete(store, provider, operation.resource),
            .read, .noop => {},
        }
    }
}

fn applyCreate(
    allocator: std.mem.Allocator,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    node: resource_mod.ResourceNode,
    final_status: state_mod.ResourceStatus,
) ApplyError!void {
    try putPendingState(store, node, .creating);
    var result = provider.create(allocator, node) catch |err| {
        try store.markFailed(node.id);
        return err;
    };
    defer result.deinit();
    try putResultState(store, node, result, final_status);
}

fn applyUpdate(
    allocator: std.mem.Allocator,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    node: resource_mod.ResourceNode,
) ApplyError!void {
    try putPendingState(store, node, .updating);
    var read = provider.read(allocator, node) catch |err| {
        try store.markFailed(node.id);
        return err;
    };
    defer read.deinit();

    var result = switch (read) {
        .absent => provider.create(allocator, node),
        .present => |*observed| provider.update(allocator, node, observed),
    } catch |err| {
        try store.markFailed(node.id);
        return err;
    };
    defer result.deinit();
    try putResultState(store, node, result, .updated);
}

fn applyReplace(
    allocator: std.mem.Allocator,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    node: resource_mod.ResourceNode,
) ApplyError!void {
    try putPendingState(store, node, .replacing);
    var read = provider.read(allocator, node) catch |err| {
        try store.markFailed(node.id);
        return err;
    };
    defer read.deinit();
    switch (read) {
        .absent => {},
        .present => |observed| provider.delete(node, observed.physical_id) catch |err| {
            try store.markFailed(node.id);
            return err;
        },
    }

    var result = provider.create(allocator, node) catch |err| {
        try store.markFailed(node.id);
        return err;
    };
    defer result.deinit();
    try putResultState(store, node, result, .created);
}

fn applyDelete(
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    node: resource_mod.ResourceNode,
) ApplyError!void {
    const existing = store.get(node.id) orelse return error.MissingRecord;
    var deleting = existing;
    deleting.status = .deleting;
    try store.put(deleting);

    const pending = store.get(node.id) orelse return error.MissingRecord;
    provider.delete(node, pending.physical_id orelse node.id) catch |err| {
        try store.markFailed(node.id);
        return err;
    };
    var deleted = store.get(node.id) orelse return error.MissingRecord;
    deleted.status = .deleted;
    deleted.operation_handle = null;
    try store.put(deleted);
}

fn putPendingState(
    store: *state_mod.InMemoryStateStore,
    node: resource_mod.ResourceNode,
    status: state_mod.ResourceStatus,
) ApplyError!void {
    const desired_hash = std.fmt.bytesToHex(node.inputs_hash, .lower);
    if (store.get(node.id)) |existing| {
        var pending = existing;
        pending.provider = node.provider;
        pending.type_name = node.type_name;
        pending.schema_version = node.schema_version;
        pending.logical_id = node.logical_id;
        pending.desired_hash = desired_hash[0..];
        pending.status = status;
        try store.put(pending);
        return;
    }
    try store.put(.{
        .resource_id = node.id,
        .provider = node.provider,
        .type_name = node.type_name,
        .schema_version = node.schema_version,
        .logical_id = node.logical_id,
        .desired_hash = desired_hash[0..],
        .status = status,
    });
}

fn putResultState(
    store: *state_mod.InMemoryStateStore,
    node: resource_mod.ResourceNode,
    result: provider_mod.ResourceResult,
    status: state_mod.ResourceStatus,
) ApplyError!void {
    const desired_hash = std.fmt.bytesToHex(node.inputs_hash, .lower);
    const observed_hash = std.fmt.bytesToHex(result.observed_hash, .lower);
    const dependencies = if (store.get(node.id)) |existing| existing.dependencies else &.{};
    try store.put(.{
        .resource_id = node.id,
        .provider = node.provider,
        .type_name = node.type_name,
        .schema_version = node.schema_version,
        .logical_id = node.logical_id,
        .physical_id = result.physical_id,
        .desired_hash = desired_hash[0..],
        .observed_hash = observed_hash[0..],
        .dependencies = dependencies,
        .outputs = result.outputs,
        .status = status,
        .operation_handle = result.operation_handle,
    });
}
