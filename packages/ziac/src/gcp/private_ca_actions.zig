const std = @import("std");
const contract = @import("../agent_contract.zig");
const client_mod = @import("client.zig");
const provider = @import("../provider.zig");

pub const Action = enum { enable_authority, disable_authority, soft_delete_authority, undelete_authority, revoke_certificate };
pub const RevocationReason = enum { unspecified, key_compromise, certificate_authority_compromise, affiliation_changed, superseded, cessation_of_operation, certificate_hold, privilege_withdrawn, attribute_authority_compromise };

pub const Target = struct {
    stage: []const u8,
    project: []const u8,
    resource_name: []const u8,
    reason: RevocationReason = .unspecified,
    now_millis: u64,
    started_at_millis: u64,
};

pub const Receipt = struct {
    allocator: std.mem.Allocator,
    action: Action,
    resource_name: []const u8,
    previous_state: []const u8,
    resulting_state: []const u8,
    operation_name: []const u8,
    action_digest: []const u8,

    pub fn deinit(self: *Receipt) void {
        self.allocator.free(self.resource_name);
        self.allocator.free(self.previous_state);
        self.allocator.free(self.resulting_state);
        self.allocator.free(self.operation_name);
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
        const destructive = action == .soft_delete_authority or action == .revoke_certificate;
        try envelope.require(.{
            .now_millis = target.now_millis,
            .started_at_millis = target.started_at_millis,
            .stage = target.stage,
            .project = target.project,
            .provider = .gcp,
            .action = if (destructive) .delete else .apply,
            .creates = 0,
            .updates = if (destructive) 0 else 1,
            .deletes = if (destructive) 1 else 0,
            .regions = 1,
            .plan_digest = digest,
        });
        const read_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{target.resource_name});
        defer context.allocator.free(read_path);
        var before_response = try self.request(context, "GET", read_path, "");
        defer before_response.deinit(context.allocator);
        var before = try std.json.parseFromSlice(std.json.Value, context.allocator, before_response.body, .{});
        defer before.deinit();
        const before_object = jsonObject(before.value) orelse return error.ProviderBug;
        const previous_state = if (action == .revoke_certificate)
            if (before_object.get("revocationDetails") == null) "ACTIVE" else "REVOKED"
        else
            jsonString(before_object.get("state")) orelse return error.ProviderBug;
        try validateTransition(action, previous_state);
        const body = if (action == .revoke_certificate)
            try std.json.Stringify.valueAlloc(context.allocator, .{ .reason = revocationReasonWire(target.reason) }, .{})
        else
            try context.allocator.dupe(u8, "{}");
        defer context.allocator.free(body);
        const action_path = switch (action) {
            .soft_delete_authority => try std.fmt.allocPrint(context.allocator, "/v1/{s}?skipGracePeriod=false&ignoreActiveCertificates=false", .{target.resource_name}),
            else => try std.fmt.allocPrint(context.allocator, "/v1/{s}:{s}", .{ target.resource_name, actionSuffix(action) }),
        };
        defer context.allocator.free(action_path);
        var after_response = try self.request(context, if (action == .soft_delete_authority) "DELETE" else "POST", action_path, body);
        defer after_response.deinit(context.allocator);
        var after = try std.json.parseFromSlice(std.json.Value, context.allocator, after_response.body, .{});
        defer after.deinit();
        const operation_name = jsonString((jsonObject(after.value) orelse return error.ProviderBug).get("name")) orelse return error.ProviderBug;
        if (std.mem.indexOf(u8, operation_name, "/operations/") == null) return error.ProviderBug;
        return .{
            .allocator = context.allocator,
            .action = action,
            .resource_name = try context.allocator.dupe(u8, target.resource_name),
            .previous_state = try context.allocator.dupe(u8, previous_state),
            .resulting_state = try context.allocator.dupe(u8, pendingState(action)),
            .operation_name = try context.allocator.dupe(u8, operation_name),
            .action_digest = try context.allocator.dupe(u8, digest),
        };
    }

    fn request(self: Runner, context: *provider.OperationContext, method: []const u8, path: []const u8, body: []const u8) !@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .private_ca, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

pub fn actionDigest(action: Action, target: Target) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    digestField(&hasher, @tagName(action));
    digestField(&hasher, target.stage);
    digestField(&hasher, target.project);
    digestField(&hasher, target.resource_name);
    digestField(&hasher, @tagName(target.reason));
    var bytes: [32]u8 = undefined;
    hasher.final(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn validateTarget(action: Action, target: Target) !void {
    if (target.stage.len == 0 or target.project.len == 0 or target.resource_name.len == 0 or std.mem.indexOfAny(u8, target.resource_name, "?# \t\r\n") != null) return error.InvalidActionTarget;
    const prefix = try std.fmt.allocPrint(std.heap.page_allocator, "projects/{s}/locations/", .{target.project});
    defer std.heap.page_allocator.free(prefix);
    if (!std.mem.startsWith(u8, target.resource_name, prefix)) return error.InvalidActionTarget;
    if (action == .revoke_certificate) {
        if (std.mem.indexOf(u8, target.resource_name, "/certificates/") == null or target.reason == .unspecified) return error.InvalidActionTarget;
    } else if (std.mem.indexOf(u8, target.resource_name, "/certificateAuthorities/") == null or target.reason != .unspecified) return error.InvalidActionTarget;
}

fn validateTransition(action: Action, state: []const u8) !void {
    const valid = switch (action) {
        .enable_authority => std.mem.eql(u8, state, "DISABLED") or std.mem.eql(u8, state, "STAGED"),
        .disable_authority => std.mem.eql(u8, state, "ENABLED"),
        .soft_delete_authority => std.mem.eql(u8, state, "DISABLED") or std.mem.eql(u8, state, "STAGED"),
        .undelete_authority => std.mem.eql(u8, state, "DELETED"),
        .revoke_certificate => std.mem.eql(u8, state, "ACTIVE"),
    };
    if (!valid) return error.InvalidResourceState;
}

fn actionSuffix(action: Action) []const u8 {
    return switch (action) {
        .enable_authority => "enable",
        .disable_authority => "disable",
        .undelete_authority => "undelete",
        .revoke_certificate => "revoke",
        .soft_delete_authority => unreachable,
    };
}
fn pendingState(action: Action) []const u8 {
    return switch (action) {
        .enable_authority => "ENABLE_PENDING",
        .disable_authority => "DISABLE_PENDING",
        .soft_delete_authority => "DELETE_PENDING",
        .undelete_authority => "UNDELETE_PENDING",
        .revoke_certificate => "REVOCATION_PENDING",
    };
}
fn revocationReasonWire(reason: RevocationReason) []const u8 {
    return switch (reason) {
        .unspecified => "REVOCATION_REASON_UNSPECIFIED",
        .key_compromise => "KEY_COMPROMISE",
        .certificate_authority_compromise => "CERTIFICATE_AUTHORITY_COMPROMISE",
        .affiliation_changed => "AFFILIATION_CHANGED",
        .superseded => "SUPERSEDED",
        .cessation_of_operation => "CESSATION_OF_OPERATION",
        .certificate_hold => "CERTIFICATE_HOLD",
        .privilege_withdrawn => "PRIVILEGE_WITHDRAWN",
        .attribute_authority_compromise => "ATTRIBUTE_AUTHORITY_COMPROMISE",
    };
}
fn digestField(hasher: *std.crypto.hash.sha2.Sha256, field: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, field.len, .little);
    hasher.update(&length);
    hasher.update(field);
}
fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return if (input == .object) input.object else null;
}
fn jsonString(input: ?std.json.Value) ?[]const u8 {
    const selected = input orelse return null;
    return if (selected == .string) selected.string else null;
}
