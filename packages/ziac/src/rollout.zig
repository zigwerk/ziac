const std = @import("std");
const resource = @import("resource.zig");
const state_mod = @import("state.zig");
const value = @import("value.zig");

pub const Error = resource.ResourceGraphError || state_mod.StateError || error{
    InvalidServiceInputs,
    RollbackHistoryIncomplete,
    RollbackImageNotImmutable,
    RollbackStateDiverged,
    RollbackUnavailable,
};

pub const RollbackGraph = struct {
    graph: resource.ResourceGraph,
    target_count: usize,

    pub fn deinit(self: *RollbackGraph) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub fn buildRollbackGraphAlloc(
    allocator: std.mem.Allocator,
    desired: *const resource.ResourceGraph,
    state: *state_mod.InMemoryStateStore,
) Error!RollbackGraph {
    var graph = resource.ResourceGraph.init(allocator);
    errdefer graph.deinit();
    var target_count: usize = 0;

    for (desired.resources.items) |node| {
        if (!std.mem.eql(u8, node.type_name, "gcp.run.Service")) {
            try graph.addResource(node);
            continue;
        }

        const record = state.get(node.id) orelse return error.RollbackHistoryIncomplete;
        const desired_image = try resolveDesiredImage(node, state);
        const current_image = outputString(record.outputs, "image_ref") orelse return error.RollbackHistoryIncomplete;
        try validateImmutableImage(current_image);

        const target_image = if (std.mem.eql(u8, current_image, desired_image)) target: {
            const previous = outputString(record.outputs, "previous_image_ref") orelse
                return error.RollbackHistoryIncomplete;
            try validateImmutableImage(previous);
            if (std.mem.eql(u8, previous, current_image)) return error.RollbackHistoryIncomplete;
            target_count += 1;
            break :target previous;
        } else current_image;

        try addServiceWithImage(allocator, &graph, node, target_image);
        if (!std.mem.eql(u8, current_image, desired_image)) {
            const cloned = graph.resources.items[graph.resources.items.len - 1];
            if (!hashMatches(cloned.inputs_hash, record.desired_hash) and
                !hashMatchesOptional(cloned.inputs_hash, record.observed_hash)) return error.RollbackStateDiverged;
        }
    }

    for (desired.dependencies.items) |edge| try graph.addDependency(edge.from, edge.to);
    try graph.validateAcyclic();
    if (target_count == 0) return error.RollbackUnavailable;
    return .{ .graph = graph, .target_count = target_count };
}

pub fn isImmutableImage(image: []const u8) bool {
    const marker = "@sha256:";
    const marker_index = std.mem.lastIndexOf(u8, image, marker) orelse return false;
    if (marker_index == 0) return false;
    const digest = image[marker_index + marker.len ..];
    if (digest.len != 64) return false;
    for (digest) |character| {
        if (!std.ascii.isDigit(character) and !(character >= 'a' and character <= 'f')) return false;
    }
    return true;
}

fn validateImmutableImage(image: []const u8) Error!void {
    if (!isImmutableImage(image)) return error.RollbackImageNotImmutable;
}

fn resolveDesiredImage(
    node: resource.ResourceNode,
    state: *state_mod.InMemoryStateStore,
) Error![]const u8 {
    const image = inputValue(node.inputs, "image") orelse return error.InvalidServiceInputs;
    return switch (image) {
        .string => |text| text,
        .output_ref => |reference| resolved: {
            const record = state.get(reference.resource_id) orelse return error.RollbackHistoryIncomplete;
            break :resolved outputString(record.outputs, reference.field) orelse return error.RollbackHistoryIncomplete;
        },
        else => error.InvalidServiceInputs,
    };
}

fn addServiceWithImage(
    allocator: std.mem.Allocator,
    graph: *resource.ResourceGraph,
    node: resource.ResourceNode,
    image: []const u8,
) Error!void {
    const original_fields = switch (node.inputs) {
        .object => |fields| fields,
        else => return error.InvalidServiceInputs,
    };
    const fields = try allocator.dupe(value.Field, original_fields);
    defer allocator.free(fields);
    var found = false;
    for (fields) |*field| {
        if (!std.mem.eql(u8, field.name, "image")) continue;
        field.value = .{ .string = image };
        found = true;
        break;
    }
    if (!found) return error.InvalidServiceInputs;
    var rollback_node = node;
    rollback_node.inputs = .{ .object = fields };
    try graph.addResource(rollback_node);
}

fn inputValue(input: value.Value, name: []const u8) ?value.Value {
    const fields = switch (input) {
        .object => |items| items,
        else => return null,
    };
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn outputString(outputs: []const state_mod.StateOutput, name: []const u8) ?[]const u8 {
    for (outputs) |provider_output| {
        if (!std.mem.eql(u8, provider_output.name, name)) continue;
        return switch (provider_output.value) {
            .string => |text| text,
            else => null,
        };
    }
    return null;
}

fn hashMatches(hash: [32]u8, encoded: []const u8) bool {
    const hex = std.fmt.bytesToHex(hash, .lower);
    return std.mem.eql(u8, hex[0..], encoded);
}

fn hashMatchesOptional(hash: [32]u8, encoded: ?[]const u8) bool {
    return if (encoded) |text| hashMatches(hash, text) else false;
}
