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
        try applyOperation(allocator, operation, store, provider);
    }
}

pub fn applyOperation(
    allocator: std.mem.Allocator,
    operation: plan_mod.PlanOperation,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
) ApplyError!void {
    var context = provider_mod.OperationContext.init(allocator);
    return applyOperationWithContext(&context, operation, store, provider);
}

pub fn applyOperationWithContext(
    context: *provider_mod.OperationContext,
    operation: plan_mod.PlanOperation,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
) ApplyError!void {
    switch (operation.kind) {
        .create => try applyCreate(context, store, provider, operation, .created),
        .update => try applyUpdate(context, store, provider, operation),
        .replace => try applyReplace(context, store, provider, operation),
        .delete => try applyDelete(context, store, provider, operation),
        .read, .noop => {},
    }
}

fn applyCreate(
    context: *provider_mod.OperationContext,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    operation: plan_mod.PlanOperation,
    final_status: state_mod.ResourceStatus,
) ApplyError!void {
    const node = operation.resource;
    try putPendingState(context.allocator, store, node, operation.dependencies, .creating);
    var result = provider.createWithContext(context, node) catch |err| {
        try store.markFailed(node.id);
        return err;
    };
    defer result.deinit();
    try putResultState(store, node, operation.dependencies, result, final_status);
}

fn applyUpdate(
    context: *provider_mod.OperationContext,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    operation: plan_mod.PlanOperation,
) ApplyError!void {
    const node = operation.resource;
    try putPendingState(context.allocator, store, node, operation.dependencies, .updating);
    var read = provider.readWithContext(context, node) catch |err| {
        try store.markFailed(node.id);
        return err;
    };
    defer read.deinit();

    var result = switch (read) {
        .absent => provider.createWithContext(context, node),
        .present => |*observed| provider.updateWithContext(context, node, observed),
    } catch |err| {
        try store.markFailed(node.id);
        return err;
    };
    defer result.deinit();
    try putResultState(store, node, operation.dependencies, result, .updated);
}

fn applyReplace(
    context: *provider_mod.OperationContext,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    operation: plan_mod.PlanOperation,
) ApplyError!void {
    const node = operation.resource;
    try putPendingState(context.allocator, store, node, operation.dependencies, .replacing);
    var read = provider.readWithContext(context, node) catch |err| {
        try store.markFailed(node.id);
        return err;
    };
    defer read.deinit();
    switch (read) {
        .absent => {},
        .present => |observed| provider.deleteWithContext(context, node, observed.physical_id) catch |err| {
            try store.markFailed(node.id);
            return err;
        },
    }

    var result = provider.createWithContext(context, node) catch |err| {
        try store.markFailed(node.id);
        return err;
    };
    defer result.deinit();
    try putResultState(store, node, operation.dependencies, result, .created);
}

fn applyDelete(
    context: *provider_mod.OperationContext,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    operation: plan_mod.PlanOperation,
) ApplyError!void {
    const node = operation.resource;
    var existing = (try store.getOwned(context.allocator, node.id)) orelse return error.MissingRecord;
    defer existing.deinit(context.allocator);
    var deleting = existing;
    deleting.status = .deleting;
    try store.put(deleting);

    if (!node.lifecycle.retain_on_delete) {
        provider.deleteWithContext(context, node, existing.physical_id orelse node.id) catch |err| {
            try store.markFailed(node.id);
            return err;
        };
    }
    existing.status = .deleted;
    existing.operation_handle = null;
    try store.put(existing);
}

fn putPendingState(
    allocator: std.mem.Allocator,
    store: *state_mod.InMemoryStateStore,
    node: resource_mod.ResourceNode,
    dependencies: []const []const u8,
    status: state_mod.ResourceStatus,
) ApplyError!void {
    const desired_hash = std.fmt.bytesToHex(node.inputs_hash, .lower);
    if (try store.getOwned(allocator, node.id)) |owned_existing| {
        var existing = owned_existing;
        defer existing.deinit(allocator);
        var pending = existing;
        pending.provider = node.provider;
        pending.type_name = node.type_name;
        pending.schema_version = node.schema_version;
        pending.logical_id = node.logical_id;
        pending.desired_hash = desired_hash[0..];
        pending.dependencies = dependencies;
        pending.protect = node.lifecycle.protect;
        pending.retain_on_delete = node.lifecycle.retain_on_delete;
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
        .dependencies = dependencies,
        .protect = node.lifecycle.protect,
        .retain_on_delete = node.lifecycle.retain_on_delete,
        .status = status,
    });
}

fn putResultState(
    store: *state_mod.InMemoryStateStore,
    node: resource_mod.ResourceNode,
    dependencies: []const []const u8,
    result: provider_mod.ResourceResult,
    status: state_mod.ResourceStatus,
) ApplyError!void {
    const desired_hash = std.fmt.bytesToHex(node.inputs_hash, .lower);
    const observed_hash = std.fmt.bytesToHex(result.observed_hash, .lower);
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
        .protect = node.lifecycle.protect,
        .retain_on_delete = node.lifecycle.retain_on_delete,
        .status = status,
        .operation_handle = result.operation_handle,
    });
}
