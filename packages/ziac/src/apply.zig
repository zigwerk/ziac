const std = @import("std");
const checkpoint_mod = @import("checkpoint.zig");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const resource_mod = @import("resource.zig");
const state_mod = @import("state.zig");

pub const ApplyControlError = error{OperationPending};
pub const ApplyError = provider_mod.ProviderError || state_mod.StateError || checkpoint_mod.CheckpointError || ApplyControlError;

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
    return applyOperationWithContext(&context, operation, store, provider, null);
}

pub fn applyOperationWithContext(
    context: *provider_mod.OperationContext,
    operation: plan_mod.PlanOperation,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    checkpoint: ?checkpoint_mod.Checkpoint,
) ApplyError!void {
    switch (operation.kind) {
        .create => try applyCreate(context, store, provider, operation, checkpoint, .created),
        .update => try applyUpdate(context, store, provider, operation, checkpoint),
        .replace => try applyReplace(context, store, provider, operation, checkpoint),
        .delete => try applyDelete(context, store, provider, operation, checkpoint),
        .read, .noop => {},
    }
}

fn applyCreate(
    context: *provider_mod.OperationContext,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    operation: plan_mod.PlanOperation,
    checkpoint: ?checkpoint_mod.Checkpoint,
    final_status: state_mod.ResourceStatus,
) ApplyError!void {
    const node = operation.resource;
    try putPendingState(context.allocator, store, node, operation.dependencies, .creating);
    var result = provider.createWithContext(context, node) catch |err| {
        try markFailedAndCheckpoint(store, node.id, checkpoint);
        return err;
    };
    defer result.deinit();
    try putResultState(
        store,
        node,
        operation.dependencies,
        result,
        if (result.completed) final_status else .creating,
    );
    try saveCheckpoint(checkpoint, store);
    if (!result.completed) return error.OperationPending;
}

fn applyUpdate(
    context: *provider_mod.OperationContext,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    operation: plan_mod.PlanOperation,
    checkpoint: ?checkpoint_mod.Checkpoint,
) ApplyError!void {
    const node = operation.resource;
    try putPendingState(context.allocator, store, node, operation.dependencies, .updating);
    if (store.get(node.id)) |existing| context.physical_id = existing.physical_id;
    var read = provider.readWithContext(context, node) catch |err| {
        try markFailedAndCheckpoint(store, node.id, checkpoint);
        return err;
    };
    defer read.deinit();

    var result = switch (read) {
        .absent => provider.createWithContext(context, node),
        .present => |*observed| provider.updateWithContext(context, node, observed),
    } catch |err| {
        try markFailedAndCheckpoint(store, node.id, checkpoint);
        return err;
    };
    defer result.deinit();
    try putResultState(
        store,
        node,
        operation.dependencies,
        result,
        if (result.completed) .updated else .updating,
    );
    try saveCheckpoint(checkpoint, store);
    if (!result.completed) return error.OperationPending;
}

fn applyReplace(
    context: *provider_mod.OperationContext,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    operation: plan_mod.PlanOperation,
    checkpoint: ?checkpoint_mod.Checkpoint,
) ApplyError!void {
    const node = operation.resource;
    try putPendingState(context.allocator, store, node, operation.dependencies, .replacing);
    if (store.get(node.id)) |existing| context.physical_id = existing.physical_id;
    var read = provider.readWithContext(context, node) catch |err| {
        try markFailedAndCheckpoint(store, node.id, checkpoint);
        return err;
    };
    defer read.deinit();
    switch (read) {
        .absent => {},
        .present => |observed| provider.deleteWithContext(context, node, observed.physical_id) catch |err| {
            try markFailedAndCheckpoint(store, node.id, checkpoint);
            return err;
        },
    }
    if (read == .present) try saveCheckpoint(checkpoint, store);

    var result = provider.createWithContext(context, node) catch |err| {
        try markFailedAndCheckpoint(store, node.id, checkpoint);
        return err;
    };
    defer result.deinit();
    try putResultState(
        store,
        node,
        operation.dependencies,
        result,
        if (result.completed) .created else .replacing,
    );
    try saveCheckpoint(checkpoint, store);
    if (!result.completed) return error.OperationPending;
}

fn applyDelete(
    context: *provider_mod.OperationContext,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
    operation: plan_mod.PlanOperation,
    checkpoint: ?checkpoint_mod.Checkpoint,
) ApplyError!void {
    const node = operation.resource;
    var existing = (try store.getOwned(context.allocator, node.id)) orelse return error.MissingRecord;
    defer existing.deinit(context.allocator);
    var deleting = existing;
    deleting.status = .deleting;
    try store.put(deleting);

    if (!node.lifecycle.retain_on_delete) {
        provider.deleteWithContext(context, node, existing.physical_id orelse node.id) catch |err| {
            try markFailedAndCheckpoint(store, node.id, checkpoint);
            return err;
        };
    }
    existing.status = .deleted;
    existing.operation_handle = null;
    try store.put(existing);
    try saveCheckpoint(checkpoint, store);
}

fn markFailedAndCheckpoint(
    store: *state_mod.InMemoryStateStore,
    resource_id: []const u8,
    checkpoint: ?checkpoint_mod.Checkpoint,
) ApplyError!void {
    try store.markFailed(resource_id);
    try saveCheckpoint(checkpoint, store);
}

fn saveCheckpoint(
    checkpoint: ?checkpoint_mod.Checkpoint,
    store: *state_mod.InMemoryStateStore,
) checkpoint_mod.CheckpointError!void {
    if (checkpoint) |target| try target.save(store);
}

pub fn adoptObserved(
    store: *state_mod.InMemoryStateStore,
    operation: plan_mod.PlanOperation,
    observed: provider_mod.ResourceResult,
    checkpoint: ?checkpoint_mod.Checkpoint,
) ApplyError!void {
    const desired_hash = std.fmt.bytesToHex(operation.resource.inputs_hash, .lower);
    const observed_hash = std.fmt.bytesToHex(observed.observed_hash, .lower);
    try store.put(.{
        .resource_id = operation.resource.id,
        .provider = operation.resource.provider,
        .type_name = operation.resource.type_name,
        .schema_version = operation.resource.schema_version,
        .logical_id = operation.resource.logical_id,
        .physical_id = observed.physical_id,
        .desired_hash = desired_hash[0..],
        .observed_hash = observed_hash[0..],
        .dependencies = operation.dependencies,
        .outputs = observed.outputs,
        .protect = operation.resource.lifecycle.protect,
        .retain_on_delete = operation.resource.lifecycle.retain_on_delete,
        .status = .adopted,
        .operation_handle = null,
    });
    try saveCheckpoint(checkpoint, store);
}

pub fn completeAbsentDelete(
    allocator: std.mem.Allocator,
    store: *state_mod.InMemoryStateStore,
    operation: plan_mod.PlanOperation,
    checkpoint: ?checkpoint_mod.Checkpoint,
) ApplyError!void {
    var existing = (try store.getOwned(allocator, operation.resource.id)) orelse return error.MissingRecord;
    defer existing.deinit(allocator);
    existing.status = .deleted;
    existing.operation_handle = null;
    try store.put(existing);
    try saveCheckpoint(checkpoint, store);
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
