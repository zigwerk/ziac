const std = @import("std");
const contract = @import("../agent_contract.zig");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider = @import("../provider.zig");
const rpc = @import("rpc.zig");

pub const Action = enum { run, inspect, cancel };
pub const Status = enum { pending, running, succeeded, failed, cancelled };

pub const Target = struct {
    stage: []const u8,
    project: []const u8,
    resource_name: []const u8,
    now_millis: u64,
    started_at_millis: u64 = 0,
};

pub const Receipt = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    schema: []const u8 = "ziac.gcp.run-execution-receipt.v1",
    action: Action,
    status: Status,
    resource_name: []const u8,
    execution_name: []const u8,
    execution_uid: []const u8,
    operation_name: []const u8,
    plan_digest: ?[]const u8,
    task_count: i64,
    running_count: i64,
    succeeded_count: i64,
    failed_count: i64,
    cancelled_count: i64,
    retried_count: i64,
    log_uri: []const u8,
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

    pub fn runAlloc(self: Runner, context: *provider.OperationContext, envelope: contract.CapabilityEnvelope, target: Target, plan_digest: []const u8) !Receipt {
        try validateTarget(target, .job);
        try requireDigest(.run, target, plan_digest);
        try envelope.require(.{
            .now_millis = target.now_millis,
            .started_at_millis = target.started_at_millis,
            .stage = target.stage,
            .project = target.project,
            .provider = .gcp,
            .action = .apply,
            .updates = 1,
            .regions = 1,
            .plan_digest = plan_digest,
        });
        const etag = try self.readEtagAlloc(context, rpc.cloud_run_v2.get_job, target.resource_name);
        defer context.allocator.free(etag);
        const path = try rpcPathAlloc(context.allocator, rpc.cloud_run_v2.run_job, &.{.{ .field = "name", .value = target.resource_name }}, &.{
            .{ .field = "validate_only", .value = "false" },
            .{ .field = "etag", .value = etag },
        });
        defer context.allocator.free(path);
        const handle = try self.startOperationAlloc(context, rpc.cloud_run_v2.run_job, path, "{}");
        defer context.allocator.free(handle);
        const execution = try self.waitExecutionAlloc(context, handle);
        defer context.allocator.free(execution);
        return receiptFromExecution(context.allocator, .run, target.resource_name, handle, plan_digest, execution);
    }

    pub fn inspectAlloc(self: Runner, context: *provider.OperationContext, envelope: contract.CapabilityEnvelope, target: Target) !Receipt {
        try validateTarget(target, .execution);
        try envelope.require(.{
            .now_millis = target.now_millis,
            .started_at_millis = target.started_at_millis,
            .stage = target.stage,
            .project = target.project,
            .provider = .gcp,
            .action = .read,
            .regions = 1,
        });
        const path = try rpcPathAlloc(context.allocator, rpc.cloud_run_v2.get_execution, &.{.{ .field = "name", .value = target.resource_name }}, &.{});
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .run, .method = "GET", .path = path });
        defer response.deinit(context.allocator);
        return receiptFromExecution(context.allocator, .inspect, target.resource_name, "", null, response.body);
    }

    pub fn cancelAlloc(self: Runner, context: *provider.OperationContext, envelope: contract.CapabilityEnvelope, target: Target, plan_digest: []const u8) !Receipt {
        try validateTarget(target, .execution);
        try requireDigest(.cancel, target, plan_digest);
        try envelope.require(.{
            .now_millis = target.now_millis,
            .started_at_millis = target.started_at_millis,
            .stage = target.stage,
            .project = target.project,
            .provider = .gcp,
            .action = .delete,
            .deletes = 1,
            .regions = 1,
            .plan_digest = plan_digest,
        });
        const etag = try self.readEtagAlloc(context, rpc.cloud_run_v2.get_execution, target.resource_name);
        defer context.allocator.free(etag);
        const path = try rpcPathAlloc(context.allocator, rpc.cloud_run_v2.cancel_execution, &.{.{ .field = "name", .value = target.resource_name }}, &.{
            .{ .field = "validate_only", .value = "false" },
            .{ .field = "etag", .value = etag },
        });
        defer context.allocator.free(path);
        const handle = try self.startOperationAlloc(context, rpc.cloud_run_v2.cancel_execution, path, "{}");
        defer context.allocator.free(handle);
        const execution = try self.waitExecutionAlloc(context, handle);
        defer context.allocator.free(execution);
        return receiptFromExecution(context.allocator, .cancel, target.resource_name, handle, plan_digest, execution);
    }

    fn readEtagAlloc(self: Runner, context: *provider.OperationContext, method: rpc.Method, resource_name: []const u8) ![]const u8 {
        const path = try rpcPathAlloc(context.allocator, method, &.{.{ .field = "name", .value = resource_name }}, &.{});
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .run, .method = "GET", .path = path });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, jsonString(root.get("etag")) orelse return error.Conflict) catch error.OutOfMemory;
    }

    fn startOperationAlloc(self: Runner, context: *provider.OperationContext, method: rpc.Method, path: []const u8, body: []const u8) ![]const u8 {
        var response = try self.request(context, .{ .api = .run, .method = method.rest.?.method.text(), .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, jsonString(root.get("name")) orelse return error.ProviderBug) catch error.OutOfMemory;
    }

    fn waitExecutionAlloc(self: Runner, context: *provider.OperationContext, handle: []const u8) ![]const u8 {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v2", .{std.mem.trimEnd(u8, self.client.endpoints.run, "/")});
        defer context.allocator.free(base);
        var target = try operation.Target.genericAlloc(context.allocator, base, handle);
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        defer completed.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, completed.payload, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const response = root.get("response") orelse return error.ProviderBug;
        return std.json.Stringify.valueAlloc(context.allocator, response, .{}) catch error.OutOfMemory;
    }

    fn request(self: Runner, context: *provider.OperationContext, request_value: client_mod.Request) !@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn actionDigest(action: Action, target: Target) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateDigestField(&hasher, @tagName(action));
    updateDigestField(&hasher, target.stage);
    updateDigestField(&hasher, target.project);
    updateDigestField(&hasher, target.resource_name);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn requireDigest(action: Action, target: Target, supplied: []const u8) !void {
    const expected = actionDigest(action, target);
    if (!std.mem.eql(u8, expected[0..], supplied)) return error.ActionDigestMismatch;
}

fn updateDigestField(hasher: *std.crypto.hash.sha2.Sha256, field: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, field.len, .little);
    hasher.update(&length);
    hasher.update(field);
}

const ResourceKind = enum { job, execution };

fn validateTarget(target: Target, kind: ResourceKind) !void {
    if (target.stage.len == 0 or target.project.len == 0 or target.resource_name.len == 0) return error.InvalidActionTarget;
    var parts = std.mem.splitScalar(u8, target.resource_name, '/');
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidActionTarget, "projects") or
        !std.mem.eql(u8, parts.next() orelse return error.InvalidActionTarget, target.project) or
        !std.mem.eql(u8, parts.next() orelse return error.InvalidActionTarget, "locations") or
        (parts.next() orelse return error.InvalidActionTarget).len == 0 or
        !std.mem.eql(u8, parts.next() orelse return error.InvalidActionTarget, "jobs") or
        (parts.next() orelse return error.InvalidActionTarget).len == 0)
    {
        return error.InvalidActionTarget;
    }
    if (kind == .execution) {
        if (!std.mem.eql(u8, parts.next() orelse return error.InvalidActionTarget, "executions") or (parts.next() orelse return error.InvalidActionTarget).len == 0) return error.InvalidActionTarget;
    }
    if (parts.next() != null) return error.InvalidActionTarget;
}

fn receiptFromExecution(allocator: std.mem.Allocator, action: Action, resource_name: []const u8, operation_name: []const u8, plan_digest: ?[]const u8, body: []const u8) !Receipt {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return error.ProviderBug;
    const root = jsonObject(parsed) orelse return error.ProviderBug;
    const execution_name = jsonString(root.get("name")) orelse return error.ProviderBug;
    const task_count = jsonInt64(root.get("taskCount")) orelse 0;
    const running_count = jsonInt64(root.get("runningCount")) orelse 0;
    const succeeded_count = jsonInt64(root.get("succeededCount")) orelse 0;
    const failed_count = jsonInt64(root.get("failedCount")) orelse 0;
    const cancelled_count = jsonInt64(root.get("cancelledCount")) orelse 0;
    const status: Status = if (cancelled_count > 0)
        .cancelled
    else if (failed_count > 0)
        .failed
    else if (running_count > 0 or jsonBool(root.get("reconciling"), false))
        .running
    else if (conditionSucceeded(root.get("terminalCondition")) and task_count == succeeded_count)
        .succeeded
    else
        .pending;
    return .{
        .allocator = allocator,
        .arena = arena,
        .action = action,
        .status = status,
        .resource_name = try a.dupe(u8, resource_name),
        .execution_name = try a.dupe(u8, execution_name),
        .execution_uid = try a.dupe(u8, jsonString(root.get("uid")) orelse ""),
        .operation_name = try a.dupe(u8, operation_name),
        .plan_digest = if (plan_digest) |present| try a.dupe(u8, present) else null,
        .task_count = task_count,
        .running_count = running_count,
        .succeeded_count = succeeded_count,
        .failed_count = failed_count,
        .cancelled_count = cancelled_count,
        .retried_count = jsonInt64(root.get("retriedCount")) orelse 0,
        .log_uri = try a.dupe(u8, jsonString(root.get("logUri")) orelse ""),
        .etag = try a.dupe(u8, jsonString(root.get("etag")) orelse ""),
    };
}

fn rpcPathAlloc(allocator: std.mem.Allocator, method: rpc.Method, path_parameters: []const rpc.Parameter, query_parameters: []const rpc.Parameter) ![]u8 {
    return rpc.restPathAlloc(allocator, method, path_parameters, query_parameters) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}

fn conditionSucceeded(maybe_condition: ?std.json.Value) bool {
    const condition = if (maybe_condition) |present| jsonObject(present) orelse return false else return false;
    return std.mem.eql(u8, jsonString(condition.get("state")) orelse "", "CONDITION_SUCCEEDED");
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
fn jsonBool(input: ?std.json.Value, fallback: bool) bool {
    return if (input) |present| switch (present) {
        .bool => |boolean| boolean,
        else => fallback,
    } else fallback;
}
fn jsonInt64(input: ?std.json.Value) ?i64 {
    const present = input orelse return null;
    return switch (present) {
        .integer => |number| number,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}
