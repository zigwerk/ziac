const std = @import("std");
const aip = @import("aip.zig");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const contract = @import("../agent_contract.zig");
const provider = @import("../provider.zig");

pub const Action = enum { create_release, promote, approve, advance, rollback, cancel, abandon };
pub const Status = enum { accepted, pending, pending_approval, succeeded, failed, cancelled, abandoned };

pub const Target = struct {
    stage: []const u8,
    project: []const u8,
    resource_name: []const u8,
    now_millis: u64,
    started_at_millis: u64,
};

pub const CreateReleaseArgs = struct {
    release_id: []const u8,
    skaffold_config_uri: []const u8,
    skaffold_config_path: []const u8 = "skaffold.yaml",
    skaffold_version: []const u8 = "",
    description: []const u8 = "",
};

pub const PromoteArgs = struct {
    rollout_id: []const u8,
    target_id: []const u8,
    starting_phase_id: []const u8 = "",
    description: []const u8 = "",
};

pub const RollbackArgs = struct {
    target_id: []const u8,
    rollout_id: []const u8,
    release_id: []const u8 = "",
    rollout_to_roll_back: []const u8 = "",
};

pub const SimplePayload = union(enum) {
    approve: bool,
    advance: []const u8,
    rollback: RollbackArgs,
    cancel,
    abandon,
};

pub const Receipt = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    action: Action,
    status: Status,
    resource_name: []const u8,
    operation_name: []const u8,
    plan_digest: []const u8,
    provider_state: []const u8,
    etag: []const u8,

    pub fn deinit(self: *Receipt) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub const Runner = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},

    pub fn createReleaseAlloc(self: Runner, context: *provider.OperationContext, envelope: contract.CapabilityEnvelope, target: Target, args: CreateReleaseArgs, digest: []const u8) !Receipt {
        try validateTarget(target, .pipeline);
        try validateId(args.release_id);
        if (!std.mem.startsWith(u8, args.skaffold_config_uri, "gs://") or args.skaffold_config_path.len == 0) return error.InvalidActionTarget;
        try requireExactDigest(createReleaseDigest(target, args), digest);
        try authorize(envelope, target, .apply, 1, 0, 0, digest);
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac-action", target.resource_name, args.release_id, &request_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}/releases?releaseId={s}&validateOnly=false&requestId={s}", .{ target.resource_name, args.release_id, request_id[0..] });
        defer context.allocator.free(path);
        const body = try releaseBodyAlloc(context.allocator, args);
        defer context.allocator.free(body);
        var completed = try self.startAndWaitAlloc(context, path, body);
        defer completed.deinit(context.allocator);
        return receiptFromOperation(context.allocator, .create_release, target.resource_name, digest, completed.payload);
    }

    pub fn promoteAlloc(self: Runner, context: *provider.OperationContext, envelope: contract.CapabilityEnvelope, target: Target, args: PromoteArgs, digest: []const u8) !Receipt {
        try validateTarget(target, .release);
        try validateId(args.rollout_id);
        try validateId(args.target_id);
        if (args.starting_phase_id.len != 0) try validateId(args.starting_phase_id);
        try requireExactDigest(promoteDigest(target, args), digest);
        try authorize(envelope, target, .apply, 1, 0, 0, digest);
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac-action", target.resource_name, args.rollout_id, &request_id);
        const phase_query = if (args.starting_phase_id.len == 0) "" else try std.fmt.allocPrint(context.allocator, "&startingPhaseId={s}", .{args.starting_phase_id});
        defer if (args.starting_phase_id.len != 0) context.allocator.free(phase_query);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}/rollouts?rolloutId={s}{s}&validateOnly=false&requestId={s}", .{ target.resource_name, args.rollout_id, phase_query, request_id[0..] });
        defer context.allocator.free(path);
        const body = try rolloutBodyAlloc(context.allocator, args);
        defer context.allocator.free(body);
        var completed = try self.startAndWaitAlloc(context, path, body);
        defer completed.deinit(context.allocator);
        return receiptFromOperation(context.allocator, .promote, target.resource_name, digest, completed.payload);
    }

    pub fn mutateAlloc(self: Runner, context: *provider.OperationContext, envelope: contract.CapabilityEnvelope, action: Action, target: Target, payload: SimplePayload, digest: []const u8) !Receipt {
        const kind: TargetKind = switch (action) {
            .approve, .advance, .cancel => .rollout,
            .rollback => .pipeline,
            .abandon => .release,
            else => return error.InvalidActionTarget,
        };
        try validateTarget(target, kind);
        try validatePayload(action, payload);
        try requireExactDigest(mutationDigest(action, target, payload), digest);
        const authority: contract.Action = if (action == .cancel or action == .abandon) .delete else .apply;
        try authorize(envelope, target, authority, 0, if (authority == .apply) 1 else 0, if (authority == .delete) 1 else 0, digest);
        const suffix: []const u8 = switch (action) {
            .approve => "approve",
            .advance => "advance",
            .rollback => "rollbackTarget",
            .cancel => "cancel",
            .abandon => "abandon",
            else => unreachable,
        };
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:{s}", .{ target.resource_name, suffix });
        defer context.allocator.free(path);
        const body = try simpleBodyAlloc(context.allocator, action, payload);
        defer context.allocator.free(body);
        var response = try self.request(context, "POST", path, body);
        defer response.deinit(context.allocator);
        return receiptFromResponse(context.allocator, action, target.resource_name, "", digest, response.body);
    }

    fn startAndWaitAlloc(self: Runner, context: *provider.OperationContext, path: []const u8, body: []const u8) !operation.Result {
        var response = try self.request(context, "POST", path, body);
        defer response.deinit(context.allocator);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.cloud_deploy, "/")});
        defer context.allocator.free(base);
        var target = try operation.Target.genericAlloc(context.allocator, base, handle);
        defer target.deinit(context.allocator);
        return operation.waitAlloc(self.client, context, target, self.operation_policy);
    }

    fn request(self: Runner, context: *provider.OperationContext, method: []const u8, path: []const u8, body: []const u8) !@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .cloud_deploy, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

pub fn actionDigest(action: Action, target: Target, material: []const u8) [64]u8 {
    var hasher = actionHasher(action, target);
    updateDigest(&hasher, material);
    return finishDigest(&hasher);
}

pub fn createReleaseDigest(target: Target, args: CreateReleaseArgs) [64]u8 {
    var hasher = actionHasher(.create_release, target);
    updateDigest(&hasher, args.release_id);
    updateDigest(&hasher, args.skaffold_config_uri);
    updateDigest(&hasher, args.skaffold_config_path);
    updateDigest(&hasher, args.skaffold_version);
    updateDigest(&hasher, args.description);
    return finishDigest(&hasher);
}

pub fn promoteDigest(target: Target, args: PromoteArgs) [64]u8 {
    var hasher = actionHasher(.promote, target);
    updateDigest(&hasher, args.rollout_id);
    updateDigest(&hasher, args.target_id);
    updateDigest(&hasher, args.starting_phase_id);
    updateDigest(&hasher, args.description);
    return finishDigest(&hasher);
}

pub fn mutationDigest(action: Action, target: Target, payload: SimplePayload) [64]u8 {
    var hasher = actionHasher(action, target);
    updateDigest(&hasher, @tagName(payload));
    switch (payload) {
        .approve => |approved| updateDigest(&hasher, if (approved) "true" else "false"),
        .advance => |phase| updateDigest(&hasher, phase),
        .rollback => |args| {
            updateDigest(&hasher, args.target_id);
            updateDigest(&hasher, args.rollout_id);
            updateDigest(&hasher, args.release_id);
            updateDigest(&hasher, args.rollout_to_roll_back);
        },
        .cancel, .abandon => {},
    }
    return finishDigest(&hasher);
}

fn actionHasher(action: Action, target: Target) std.crypto.hash.sha2.Sha256 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateDigest(&hasher, @tagName(action));
    updateDigest(&hasher, target.stage);
    updateDigest(&hasher, target.project);
    updateDigest(&hasher, target.resource_name);
    return hasher;
}

fn finishDigest(hasher: *std.crypto.hash.sha2.Sha256) [64]u8 {
    var bytes: [32]u8 = undefined;
    hasher.final(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn requireExactDigest(expected: [64]u8, supplied: []const u8) !void {
    if (!std.mem.eql(u8, expected[0..], supplied)) return error.ActionDigestMismatch;
}

fn updateDigest(hasher: *std.crypto.hash.sha2.Sha256, field: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, field.len, .little);
    hasher.update(&length);
    hasher.update(field);
}

fn authorize(envelope: contract.CapabilityEnvelope, target: Target, action: contract.Action, creates: usize, updates: usize, deletes: usize, digest: []const u8) !void {
    try envelope.require(.{
        .now_millis = target.now_millis,
        .started_at_millis = target.started_at_millis,
        .stage = target.stage,
        .project = target.project,
        .provider = .gcp,
        .action = action,
        .creates = creates,
        .updates = updates,
        .deletes = deletes,
        .regions = 1,
        .plan_digest = digest,
    });
}

fn validatePayload(action: Action, payload: SimplePayload) !void {
    switch (payload) {
        .approve => if (action != .approve) return error.InvalidActionTarget,
        .advance => |phase| {
            if (action != .advance) return error.InvalidActionTarget;
            try validateId(phase);
        },
        .rollback => |args| {
            if (action != .rollback) return error.InvalidActionTarget;
            try validateId(args.target_id);
            try validateId(args.rollout_id);
            if (args.release_id.len != 0) try validateId(args.release_id);
            if (args.rollout_to_roll_back.len != 0 and std.mem.indexOf(u8, args.rollout_to_roll_back, "/rollouts/") == null) return error.InvalidActionTarget;
        },
        .cancel => if (action != .cancel) return error.InvalidActionTarget,
        .abandon => if (action != .abandon) return error.InvalidActionTarget,
    }
}

const TargetKind = enum { pipeline, release, rollout };

fn validateTarget(target: Target, kind: TargetKind) !void {
    if (target.stage.len == 0 or target.project.len == 0 or target.resource_name.len == 0 or std.mem.indexOfAny(u8, target.resource_name, "?# \t\r\n") != null) return error.InvalidActionTarget;
    const prefix = try std.fmt.allocPrint(std.heap.page_allocator, "projects/{s}/locations/", .{target.project});
    defer std.heap.page_allocator.free(prefix);
    if (!std.mem.startsWith(u8, target.resource_name, prefix) or std.mem.indexOf(u8, target.resource_name, "/deliveryPipelines/") == null) return error.InvalidActionTarget;
    const has_release = std.mem.indexOf(u8, target.resource_name, "/releases/") != null;
    const has_rollout = std.mem.indexOf(u8, target.resource_name, "/rollouts/") != null;
    if ((kind == .pipeline and (has_release or has_rollout)) or (kind == .release and (!has_release or has_rollout)) or (kind == .rollout and !has_rollout)) return error.InvalidActionTarget;
}

fn validateId(id: []const u8) !void {
    if (id.len == 0 or id.len > 63 or !std.ascii.isLower(id[0])) return error.InvalidActionTarget;
    for (id) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidActionTarget;
}

fn releaseBodyAlloc(allocator: std.mem.Allocator, args: CreateReleaseArgs) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    try root.put(arena, "skaffoldConfigUri", .{ .string = args.skaffold_config_uri });
    try root.put(arena, "skaffoldConfigPath", .{ .string = args.skaffold_config_path });
    if (args.skaffold_version.len != 0) try root.put(arena, "skaffoldVersion", .{ .string = args.skaffold_version });
    if (args.description.len != 0) try root.put(arena, "description", .{ .string = args.description });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{});
}

fn rolloutBodyAlloc(allocator: std.mem.Allocator, args: PromoteArgs) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    try root.put(arena, "targetId", .{ .string = args.target_id });
    if (args.description.len != 0) try root.put(arena, "description", .{ .string = args.description });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{});
}

fn simpleBodyAlloc(allocator: std.mem.Allocator, action: Action, payload: SimplePayload) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    switch (payload) {
        .approve => |approved| {
            if (action != .approve) return error.InvalidActionTarget;
            try root.put(arena, "approved", .{ .bool = approved });
        },
        .advance => |phase| {
            if (action != .advance) return error.InvalidActionTarget;
            try validateId(phase);
            try root.put(arena, "phaseId", .{ .string = phase });
        },
        .rollback => |args| {
            if (action != .rollback) return error.InvalidActionTarget;
            try validateId(args.target_id);
            try validateId(args.rollout_id);
            try root.put(arena, "targetId", .{ .string = args.target_id });
            try root.put(arena, "rolloutId", .{ .string = args.rollout_id });
            try root.put(arena, "validateOnly", .{ .bool = false });
            if (args.release_id.len != 0) try root.put(arena, "releaseId", .{ .string = args.release_id });
            if (args.rollout_to_roll_back.len != 0) try root.put(arena, "rolloutToRollBack", .{ .string = args.rollout_to_roll_back });
        },
        .cancel => if (action != .cancel) return error.InvalidActionTarget,
        .abandon => if (action != .abandon) return error.InvalidActionTarget,
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{});
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const name = jsonString(root.get("name")) orelse return error.ProviderBug;
    if (std.mem.indexOf(u8, name, "/operations/") == null) return error.ProviderBug;
    return allocator.dupe(u8, name);
}

fn receiptFromOperation(allocator: std.mem.Allocator, action: Action, fallback_name: []const u8, digest: []const u8, body: []const u8) !Receipt {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const operation_name = jsonString(root.get("name")) orelse "";
    const response = root.get("response") orelse return error.ProviderBug;
    const response_body = try std.json.Stringify.valueAlloc(allocator, response, .{});
    defer allocator.free(response_body);
    return receiptFromResponse(allocator, action, fallback_name, operation_name, digest, response_body);
}

fn receiptFromResponse(allocator: std.mem.Allocator, action: Action, fallback_name: []const u8, operation_name: []const u8, digest: []const u8, body: []const u8) !Receipt {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return error.ProviderBug;
    const root = jsonObject(parsed) orelse return error.ProviderBug;
    const provider_state = jsonString(root.get("state")) orelse jsonString(root.get("renderState")) orelse "ACCEPTED";
    const status: Status = if (action == .cancel)
        .cancelled
    else if (action == .abandon)
        .abandoned
    else if (std.mem.eql(u8, provider_state, "SUCCEEDED"))
        .succeeded
    else if (std.mem.eql(u8, provider_state, "FAILED") or std.mem.eql(u8, provider_state, "APPROVAL_REJECTED"))
        .failed
    else if (std.mem.eql(u8, provider_state, "PENDING_APPROVAL"))
        .pending_approval
    else if (std.mem.eql(u8, provider_state, "IN_PROGRESS") or std.mem.eql(u8, provider_state, "PENDING") or std.mem.eql(u8, provider_state, "PENDING_RELEASE"))
        .pending
    else
        .accepted;
    return .{
        .allocator = allocator,
        .arena = arena,
        .action = action,
        .status = status,
        .resource_name = try a.dupe(u8, jsonString(root.get("name")) orelse jsonString(root.get("rollbackRollout")) orelse fallback_name),
        .operation_name = try a.dupe(u8, operation_name),
        .plan_digest = try a.dupe(u8, digest),
        .provider_state = try a.dupe(u8, provider_state),
        .etag = try a.dupe(u8, jsonString(root.get("etag")) orelse ""),
    };
}

fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}
fn jsonString(input: ?std.json.Value) ?[]const u8 {
    return if (input) |present| switch (present) {
        .string => |text| text,
        else => null,
    } else null;
}
