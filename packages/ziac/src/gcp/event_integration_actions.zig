const std = @import("std");
const contract = @import("../agent_contract.zig");
const client_mod = @import("client.zig");
const provider = @import("../provider.zig");

pub const Action = enum { publish_json, repair_eventing, retry_subscription, refresh_schema };
pub const Payload = union(enum) { none: void, json_event: []const u8 };
pub const Target = struct {
    stage: []const u8,
    project: []const u8,
    resource_name: []const u8,
    now_millis: u64,
    started_at_millis: u64,
};
pub const Receipt = struct {
    allocator: std.mem.Allocator,
    action: Action,
    resource_name: []const u8,
    result_name: []const u8,
    status: []const u8,
    action_digest: []const u8,

    pub fn deinit(self: *Receipt) void {
        self.allocator.free(self.resource_name);
        self.allocator.free(self.result_name);
        self.allocator.free(self.status);
        self.allocator.free(self.action_digest);
        self.* = undefined;
    }
};

pub const Runner = struct {
    client: *client_mod.Client,

    pub fn runAlloc(self: Runner, context: *provider.OperationContext, envelope: contract.CapabilityEnvelope, action: Action, target: Target, payload: Payload, digest: []const u8) !Receipt {
        try validateTarget(action, target, payload);
        const expected = actionDigest(action, target, payload);
        if (!std.mem.eql(u8, expected[0..], digest)) return error.ActionDigestMismatch;
        const authority = authorityFor(action);
        try envelope.require(.{
            .now_millis = target.now_millis,
            .started_at_millis = target.started_at_millis,
            .stage = target.stage,
            .project = target.project,
            .provider = .gcp,
            .action = .apply,
            .creates = authority.creates,
            .updates = authority.updates,
            .regions = 1,
            .plan_digest = digest,
        });
        const body = try bodyAlloc(context.allocator, payload);
        defer context.allocator.free(body);
        const path = try actionPathAlloc(context.allocator, action, target.resource_name);
        defer context.allocator.free(path);
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var response = try self.client.requestJsonAlloc(context, .{ .api = apiFor(action), .method = "POST", .path = path, .body = body }, &diagnostic);
        defer response.deinit(context.allocator);
        const result_name = try resultNameAlloc(context.allocator, action, target.resource_name, response.body);
        defer context.allocator.free(result_name);
        return .{
            .allocator = context.allocator,
            .action = action,
            .resource_name = try context.allocator.dupe(u8, target.resource_name),
            .result_name = try context.allocator.dupe(u8, result_name),
            .status = try context.allocator.dupe(u8, if (action == .publish_json) "PUBLISHED" else "OPERATION_PENDING"),
            .action_digest = try context.allocator.dupe(u8, digest),
        };
    }
};

const Authority = struct { creates: usize = 0, updates: usize = 0 };
fn authorityFor(action: Action) Authority {
    return if (action == .publish_json) .{ .creates = 1 } else .{ .updates = 1 };
}

pub fn actionDigest(action: Action, target: Target, payload: Payload) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    digestField(&hasher, @tagName(action));
    digestField(&hasher, target.stage);
    digestField(&hasher, target.project);
    digestField(&hasher, target.resource_name);
    digestField(&hasher, @tagName(payload));
    switch (payload) {
        .none => {},
        .json_event => |event| digestField(&hasher, event),
    }
    var bytes: [32]u8 = undefined;
    hasher.final(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn validateTarget(action: Action, target: Target, payload: Payload) !void {
    if (target.stage.len == 0 or target.project.len == 0 or target.resource_name.len == 0 or std.mem.indexOfAny(u8, target.resource_name, "?# \t\r\n") != null) return error.InvalidActionTarget;
    const prefix = try std.fmt.allocPrint(std.heap.page_allocator, "projects/{s}/", .{target.project});
    defer std.heap.page_allocator.free(prefix);
    if (!std.mem.startsWith(u8, target.resource_name, prefix)) return error.InvalidActionTarget;
    const valid = switch (action) {
        .publish_json => std.mem.indexOf(u8, target.resource_name, "/messageBuses/") != null,
        .repair_eventing, .refresh_schema => std.mem.indexOf(u8, target.resource_name, "/connections/") != null and std.mem.indexOf(u8, target.resource_name, "/eventSubscriptions/") == null,
        .retry_subscription => std.mem.indexOf(u8, target.resource_name, "/connections/") != null and std.mem.indexOf(u8, target.resource_name, "/eventSubscriptions/") != null,
    };
    if (!valid) return error.InvalidActionTarget;
    if ((action == .publish_json) != (payload == .json_event)) return error.InvalidActionPayload;
    if (payload == .json_event) {
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload.json_event, .{}) catch return error.InvalidActionPayload;
        defer parsed.deinit();
        const object = if (parsed.value == .object) parsed.value.object else return error.InvalidActionPayload;
        for ([_][]const u8{ "specversion", "id", "source", "type" }) |field| if (object.get(field) == null) return error.InvalidActionPayload;
    }
}

fn actionPathAlloc(allocator: std.mem.Allocator, action: Action, resource_name: []const u8) ![]u8 {
    return switch (action) {
        .publish_json => std.fmt.allocPrint(allocator, "/v1/{s}:publish", .{resource_name}),
        .repair_eventing => std.fmt.allocPrint(allocator, "/v1/{s}:repairEventing", .{resource_name}),
        .retry_subscription => std.fmt.allocPrint(allocator, "/v1/{s}:retry", .{resource_name}),
        .refresh_schema => std.fmt.allocPrint(allocator, "/v1/{s}/connectionSchemaMetadata:refresh", .{resource_name}),
    } catch error.OutOfMemory;
}
fn bodyAlloc(allocator: std.mem.Allocator, payload: Payload) ![]u8 {
    return switch (payload) {
        .none => allocator.dupe(u8, "{}"),
        .json_event => |event| std.json.Stringify.valueAlloc(allocator, .{ .jsonMessage = event }, .{}),
    } catch error.OutOfMemory;
}
fn resultNameAlloc(allocator: std.mem.Allocator, action: Action, target: []const u8, body: []const u8) ![]u8 {
    if (body.len != 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        if (parsed.value == .object) if (parsed.value.object.get("name")) |name| if (name == .string) return allocator.dupe(u8, name.string);
    }
    if (action != .publish_json) return error.ProviderBug;
    return std.fmt.allocPrint(allocator, "{s}:published", .{target});
}
fn apiFor(action: Action) client_mod.Api {
    return if (action == .publish_json) .eventarc_publishing else .connectors;
}
fn digestField(hasher: *std.crypto.hash.sha2.Sha256, field: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, field.len, .little);
    hasher.update(&length);
    hasher.update(field);
}
