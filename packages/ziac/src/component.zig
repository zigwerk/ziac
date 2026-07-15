const std = @import("std");
const provenance = @import("provenance.zig");
const resource = @import("resource.zig");

pub const Origin = provenance.Origin;

pub const Descriptor = struct {
    package: []const u8,
    name: []const u8,
    version: []const u8,
    source_digest: []const u8,
    providers: []const resource.ProviderId,
    resource_types: []const []const u8,

    pub fn validate(self: Descriptor) error{InvalidComponentDescriptor}!void {
        const candidate = Origin{
            .package = self.package,
            .name = self.name,
            .version = self.version,
            .instance = "validation",
            .source_digest = self.source_digest,
        };
        candidate.validate() catch return error.InvalidComponentDescriptor;
        if (self.providers.len == 0 or self.providers.len > 8 or self.resource_types.len == 0 or self.resource_types.len > 512) return error.InvalidComponentDescriptor;
        for (self.providers, 0..) |provider, index| for (self.providers[0..index]) |previous| if (provider == previous) return error.InvalidComponentDescriptor;
        for (self.resource_types, 0..) |type_name, index| {
            if (!validResourceType(type_name)) return error.InvalidComponentDescriptor;
            for (self.resource_types[0..index]) |previous| if (std.mem.eql(u8, type_name, previous)) return error.InvalidComponentDescriptor;
        }
    }
};

pub const StampError = std.mem.Allocator.Error || error{
    InvalidComponentDescriptor,
    InvalidComponentRange,
    InvalidComponentOrigin,
    ComponentOwnershipConflict,
    UndeclaredComponentProvider,
    UndeclaredComponentResource,
};

pub fn stampGraph(graph: *resource.ResourceGraph, descriptor: Descriptor, instance: []const u8) StampError!void {
    return stampRange(graph, 0, descriptor, instance);
}

pub fn stampRange(graph: *resource.ResourceGraph, start: usize, descriptor: Descriptor, instance: []const u8) StampError!void {
    try descriptor.validate();
    if (start > graph.resources.items.len) return error.InvalidComponentRange;
    const desired = Origin{
        .package = descriptor.package,
        .name = descriptor.name,
        .version = descriptor.version,
        .instance = instance,
        .source_digest = descriptor.source_digest,
    };
    desired.validate() catch return error.InvalidComponentOrigin;

    const selected = graph.resources.items[start..];
    for (selected) |node| {
        if (!containsProvider(descriptor.providers, node.provider)) return error.UndeclaredComponentProvider;
        if (!containsString(descriptor.resource_types, node.type_name)) return error.UndeclaredComponentResource;
        if (node.component) |existing| if (!existing.eql(desired)) return error.ComponentOwnershipConflict;
    }

    const pending = try graph.allocator.alloc(?Origin, selected.len);
    defer graph.allocator.free(pending);
    @memset(pending, null);
    errdefer for (pending) |*maybe| if (maybe.*) |*origin| origin.deinit(graph.allocator);
    for (selected, 0..) |node, index| if (node.component == null) {
        pending[index] = try Origin.initOwned(graph.allocator, desired);
    };
    for (selected, 0..) |*node, index| if (pending[index]) |origin| {
        node.component = origin;
        pending[index] = null;
    };
}

fn containsProvider(providers: []const resource.ProviderId, target: resource.ProviderId) bool {
    for (providers) |provider| if (provider == target) return true;
    return false;
}

fn containsString(values: []const []const u8, target: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, target)) return true;
    return false;
}

fn validResourceType(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or std.mem.indexOfScalar(u8, value, '.') == null) return false;
    for (value) |char| if (!(std.ascii.isAlphanumeric(char) or char == '.' or char == '_')) return false;
    return true;
}
