const std = @import("std");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const state_mod = @import("state.zig");

pub const ApplyError = error{
    DuplicateField,
    ProviderFailed,
    MissingRecord,
    OutOfMemory,
};

pub fn applyPlan(
    allocator: std.mem.Allocator,
    planned: *const plan_mod.Plan,
    store: *state_mod.InMemoryStateStore,
    provider: provider_mod.Provider,
) ApplyError!void {
    _ = allocator;

    for (planned.operations) |operation| {
        switch (operation.kind) {
            .create, .update, .replace => {
                const hash = std.fmt.bytesToHex(operation.resource.inputs_hash, .lower);
                try putOperationState(store, operation.resource, hash[0..], .creating);
                provider.reconcile(operation.resource) catch |err| {
                    try store.markFailed(operation.resource.id);
                    return err;
                };
                try putOperationState(store, operation.resource, hash[0..], .created);
            },
            .delete => {
                provider.delete(operation.resource) catch |err| {
                    try store.markFailed(operation.resource.id);
                    return err;
                };
                const existing = store.get(operation.resource.id) orelse return error.MissingRecord;
                var deleted = existing;
                deleted.status = .deleted;
                try store.put(deleted);
            },
            .read, .noop => {},
        }
    }
}

fn putOperationState(
    store: *state_mod.InMemoryStateStore,
    node: @import("resource.zig").ResourceNode,
    desired_hash: []const u8,
    status: state_mod.ResourceStatus,
) ApplyError!void {
    if (store.get(node.id)) |existing| {
        var updated = existing;
        updated.provider = node.provider;
        updated.type_name = node.type_name;
        updated.schema_version = node.schema_version;
        updated.logical_id = node.logical_id;
        updated.desired_hash = desired_hash;
        updated.status = status;
        try store.put(updated);
        return;
    }

    try store.put(.{
        .resource_id = node.id,
        .provider = node.provider,
        .type_name = node.type_name,
        .schema_version = node.schema_version,
        .logical_id = node.logical_id,
        .desired_hash = desired_hash,
        .status = status,
    });
}
