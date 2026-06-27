const std = @import("std");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const state_mod = @import("state.zig");

pub const ApplyError = error{
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
                try store.put(.{
                    .resource_id = operation.resource.id,
                    .type_name = operation.resource.type_name,
                    .logical_id = operation.resource.logical_id,
                    .inputs_hash = "v1",
                    .status = .creating,
                });
                provider.reconcile(operation.resource) catch |err| {
                    try store.markFailed(operation.resource.id);
                    return err;
                };
                try store.put(.{
                    .resource_id = operation.resource.id,
                    .type_name = operation.resource.type_name,
                    .logical_id = operation.resource.logical_id,
                    .inputs_hash = "v1",
                    .status = .created,
                });
            },
            .delete => {
                provider.delete(operation.resource) catch |err| {
                    try store.markFailed(operation.resource.id);
                    return err;
                };
                try store.put(.{
                    .resource_id = operation.resource.id,
                    .type_name = operation.resource.type_name,
                    .logical_id = operation.resource.logical_id,
                    .inputs_hash = "v1",
                    .status = .deleted,
                });
            },
            .read, .noop => {},
        }
    }
}
