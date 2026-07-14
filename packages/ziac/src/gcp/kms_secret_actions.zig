const std = @import("std");
const contract = @import("../agent_contract.zig");
const client_mod = @import("client.zig");
const provider = @import("../provider.zig");

pub const Action = enum { schedule_kms_destroy, restore_kms_version, destroy_secret_version };

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
    previous_state: []const u8,
    resulting_state: []const u8,
    destroy_time: ?[]const u8,
    action_digest: []const u8,

    pub fn deinit(self: *Receipt) void {
        self.allocator.free(self.resource_name);
        self.allocator.free(self.previous_state);
        self.allocator.free(self.resulting_state);
        if (self.destroy_time) |time| self.allocator.free(time);
        self.allocator.free(self.action_digest);
        self.* = undefined;
    }
};

pub const Runner = struct {
    client: *client_mod.Client,

    pub fn runAlloc(self: Runner, context: *provider.OperationContext, envelope: contract.CapabilityEnvelope, action: Action, target: Target, digest: []const u8) !Receipt {
        try validateTarget(action, target);
        const expected = actionDigest(action, target);
        if (!std.mem.eql(u8, expected[0..], digest)) return error.ActionDigestMismatch;
        const authority: contract.Action = if (action == .restore_kms_version) .apply else .delete;
        try envelope.require(.{
            .now_millis = target.now_millis,
            .started_at_millis = target.started_at_millis,
            .stage = target.stage,
            .project = target.project,
            .provider = .gcp,
            .action = authority,
            .creates = 0,
            .updates = if (authority == .apply) 1 else 0,
            .deletes = if (authority == .delete) 1 else 0,
            .regions = 1,
            .plan_digest = digest,
        });
        const api: client_mod.Api = if (action == .destroy_secret_version) .secret_manager else .cloud_kms;
        const read_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{target.resource_name});
        defer context.allocator.free(read_path);
        var before_response = try self.request(context, api, "GET", read_path, "");
        defer before_response.deinit(context.allocator);
        var before = try std.json.parseFromSlice(std.json.Value, context.allocator, before_response.body, .{});
        defer before.deinit();
        const before_object = jsonObject(before.value) orelse return error.ProviderBug;
        const previous_state = jsonString(before_object.get("state")) orelse return error.ProviderBug;
        try validateTransition(action, previous_state);
        const suffix: []const u8 = switch (action) {
            .schedule_kms_destroy, .destroy_secret_version => "destroy",
            .restore_kms_version => "restore",
        };
        const action_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:{s}", .{ target.resource_name, suffix });
        defer context.allocator.free(action_path);
        const body = if (action == .destroy_secret_version) blk: {
            const etag = jsonString(before_object.get("etag")) orelse return error.InvalidConfiguration;
            break :blk try std.json.Stringify.valueAlloc(context.allocator, .{ .etag = etag }, .{});
        } else try context.allocator.dupe(u8, "{}");
        defer context.allocator.free(body);
        var after_response = try self.request(context, api, "POST", action_path, body);
        defer after_response.deinit(context.allocator);
        var after = try std.json.parseFromSlice(std.json.Value, context.allocator, after_response.body, .{});
        defer after.deinit();
        const after_object = jsonObject(after.value) orelse return error.ProviderBug;
        return .{
            .allocator = context.allocator,
            .action = action,
            .resource_name = try context.allocator.dupe(u8, target.resource_name),
            .previous_state = try context.allocator.dupe(u8, previous_state),
            .resulting_state = try context.allocator.dupe(u8, jsonString(after_object.get("state")) orelse return error.ProviderBug),
            .destroy_time = if (jsonString(after_object.get("destroyTime"))) |time| try context.allocator.dupe(u8, time) else null,
            .action_digest = try context.allocator.dupe(u8, digest),
        };
    }

    fn request(self: Runner, context: *provider.OperationContext, api: client_mod.Api, method: []const u8, path: []const u8, body: []const u8) !@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = api, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

pub fn actionDigest(action: Action, target: Target) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    digestField(&hasher, @tagName(action));
    digestField(&hasher, target.stage);
    digestField(&hasher, target.project);
    digestField(&hasher, target.resource_name);
    var bytes: [32]u8 = undefined;
    hasher.final(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn validateTarget(action: Action, target: Target) !void {
    if (target.stage.len == 0 or target.project.len == 0 or target.resource_name.len == 0 or std.mem.indexOfAny(u8, target.resource_name, "?# \t\r\n") != null) return error.InvalidActionTarget;
    const prefix = try std.fmt.allocPrint(std.heap.page_allocator, "projects/{s}/", .{target.project});
    defer std.heap.page_allocator.free(prefix);
    if (!std.mem.startsWith(u8, target.resource_name, prefix)) return error.InvalidActionTarget;
    if (action == .destroy_secret_version) {
        if (std.mem.indexOf(u8, target.resource_name, "/secrets/") == null or std.mem.indexOf(u8, target.resource_name, "/versions/") == null) return error.InvalidActionTarget;
    } else if (std.mem.indexOf(u8, target.resource_name, "/cryptoKeyVersions/") == null) return error.InvalidActionTarget;
}

fn validateTransition(action: Action, state: []const u8) !void {
    const valid = switch (action) {
        .schedule_kms_destroy => std.mem.eql(u8, state, "ENABLED") or std.mem.eql(u8, state, "DISABLED"),
        .restore_kms_version => std.mem.eql(u8, state, "DESTROY_SCHEDULED"),
        .destroy_secret_version => std.mem.eql(u8, state, "ENABLED") or std.mem.eql(u8, state, "DISABLED"),
    };
    if (!valid) return error.InvalidResourceState;
}

fn digestField(hasher: *std.crypto.hash.sha2.Sha256, field: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, field.len, .little);
    hasher.update(&length);
    hasher.update(field);
}
fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}
fn jsonString(input: ?std.json.Value) ?[]const u8 {
    return switch (input orelse return null) {
        .string => |text| text,
        else => null,
    };
}
