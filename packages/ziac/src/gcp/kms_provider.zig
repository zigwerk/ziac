const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const Kind = enum { key_ring, crypto_key };

pub const Handler = struct {
    client: *client_mod.Client,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const physical = try physicalIdAlloc(context, node);
        defer context.allocator.free(physical);
        if (physical_override) |expected| if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .cloud_kms, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, physical, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const change: provider_mod.DiffKind = if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) .noop else switch (kind(node) orelse return error.InvalidConfiguration) {
            .key_ring => .replace,
            .crypto_key => .update,
        };
        return provider_mod.DiffResult.init(context.allocator, change, if (change == .noop) &.{} else &.{"Cloud KMS desired state differs from observed resource"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const path = switch (resource_kind) {
            .key_ring => try keyRingCreatePathAlloc(context.allocator, node),
            .crypto_key => try cryptoKeyCreatePathAlloc(context, node),
        };
        defer context.allocator.free(path);
        const body = switch (resource_kind) {
            .key_ring => try context.allocator.dupe(u8, "{}"),
            .crypto_key => try cryptoKeyBodyAlloc(context.allocator, node),
        };
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .cloud_kms, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        const physical = try physicalIdAlloc(context, node);
        defer context.allocator.free(physical);
        return resultFromJson(context, node, physical, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        if (kind(node) != .crypto_key) return error.InvalidConfiguration;
        const expected = try physicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask=rotationPeriod", .{physical_id});
        defer context.allocator.free(path);
        const body = try cryptoKeyBodyAlloc(context.allocator, node);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .cloud_kms, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, physical_id, response.body);
    }

    pub fn delete(_: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const expected = try physicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        // Key rings cannot be deleted and bootstrap keys are retained intentionally.
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return kind(node) != null;
}
fn kind(node: resource.ResourceNode) ?Kind {
    if (std.mem.eql(u8, node.type_name, "gcp.kms.KeyRing")) return .key_ring;
    if (std.mem.eql(u8, node.type_name, "gcp.kms.CryptoKey")) return .crypto_key;
    return null;
}
fn physicalIdAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    return switch (kind(node) orelse return error.InvalidConfiguration) {
        .key_ring => std.fmt.allocPrint(context.allocator, "projects/{s}/locations/{s}/keyRings/{s}", .{ project, try requiredString(node.inputs, "location"), name }) catch error.OutOfMemory,
        .crypto_key => {
            const ring = try resolveString(context, try requiredValue(node.inputs, "key_ring"));
            return std.fmt.allocPrint(context.allocator, "{s}/cryptoKeys/{s}", .{ ring, name }) catch error.OutOfMemory;
        },
    };
}
fn keyRingCreatePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]u8 {
    return std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/keyRings?keyRingId={s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "location"),
        try requiredString(node.inputs, "name"),
    }) catch error.OutOfMemory;
}
fn cryptoKeyCreatePathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]u8 {
    const ring = try resolveString(context, try requiredValue(node.inputs, "key_ring"));
    return std.fmt.allocPrint(context.allocator, "/v1/{s}/cryptoKeys?cryptoKeyId={s}", .{ ring, try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
}
fn cryptoKeyBodyAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]u8 {
    const seconds = try requiredInteger(node.inputs, "rotation_period_seconds");
    const period = std.fmt.allocPrint(allocator, "{d}s", .{seconds}) catch return error.OutOfMemory;
    defer allocator.free(period);
    return std.json.Stringify.valueAlloc(allocator, .{ .purpose = "ENCRYPT_DECRYPT", .rotationPeriod = period }, .{}) catch error.OutOfMemory;
}
fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = switch (parsed.value) {
        .object => |object| object,
        else => return error.ProviderBug,
    };
    const remote_name = switch (remote.get("name") orelse return error.ProviderBug) {
        .string => |name| name,
        else => return error.ProviderBug,
    };
    if (!std.mem.eql(u8, remote_name, physical)) return error.InvalidConfiguration;
    const outputs = [_]state.StateOutput{.{ .name = "name", .value = .{ .string = physical } }};
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}
fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    if (input != .object) return error.InvalidConfiguration;
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(input, name)) {
        .string => |entry| entry,
        else => error.InvalidConfiguration,
    };
}
fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |entry| entry,
        else => error.InvalidConfiguration,
    };
}
fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |entry| entry,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}
