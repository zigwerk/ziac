const std = @import("std");
const apply_mod = @import("apply.zig");
const checkpoint_mod = @import("checkpoint.zig");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const resource_mod = @import("resource.zig");
const state_mod = @import("state.zig");

pub const ImportValidationError = error{InvalidProviderIdentifier};
pub const ImportError = ImportValidationError || apply_mod.ApplyError || provider_mod.ProviderError;

pub fn importResource(
    allocator: std.mem.Allocator,
    node: resource_mod.ResourceNode,
    physical_id: []const u8,
    store: *state_mod.InMemoryStateStore,
    providers: provider_mod.ProviderRegistry,
    checkpoint: ?checkpoint_mod.Checkpoint,
) ImportError!void {
    try validateProviderIdentifier(physical_id);
    const provider = try providers.get(node.provider);
    var context = provider_mod.OperationContext.init(allocator);
    var imported = try provider.importWithContext(&context, node, physical_id);
    defer imported.deinit();
    try apply_mod.adoptObserved(
        store,
        .{
            .kind = .read,
            .resource = node,
        },
        imported,
        checkpoint,
    );
}

pub fn validateProviderIdentifier(physical_id: []const u8) ImportValidationError!void {
    if (physical_id.len == 0 or physical_id.len > 2048) return error.InvalidProviderIdentifier;
    if (std.mem.indexOf(u8, physical_id, "://") != null) return error.InvalidProviderIdentifier;
    for (physical_id) |character| {
        if (character <= 0x20 or character == 0x7f) return error.InvalidProviderIdentifier;
    }
}
