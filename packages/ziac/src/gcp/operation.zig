const std = @import("std");
const client_mod = @import("client.zig");
const provider = @import("../provider.zig");
const provider_error = @import("../provider_error.zig");

pub const ProviderError = provider_error.ProviderError;

pub const Kind = enum {
    generic,
    compute_global,
    compute_regional,
};

pub const Target = struct {
    kind: Kind,
    url: []const u8,

    pub fn genericAlloc(
        allocator: std.mem.Allocator,
        base_url: []const u8,
        operation_name: []const u8,
    ) std.mem.Allocator.Error!Target {
        return .{ .kind = .generic, .url = try joinUrlAlloc(allocator, base_url, operation_name) };
    }

    pub fn computeGlobalAlloc(
        allocator: std.mem.Allocator,
        base_url: []const u8,
        project_id: []const u8,
        operation_name: []const u8,
    ) std.mem.Allocator.Error!Target {
        return .{
            .kind = .compute_global,
            .url = try std.fmt.allocPrint(
                allocator,
                "{s}/projects/{s}/global/operations/{s}",
                .{ std.mem.trimEnd(u8, base_url, "/"), project_id, operation_name },
            ),
        };
    }

    pub fn computeRegionalAlloc(
        allocator: std.mem.Allocator,
        base_url: []const u8,
        project_id: []const u8,
        region: []const u8,
        operation_name: []const u8,
    ) std.mem.Allocator.Error!Target {
        return .{
            .kind = .compute_regional,
            .url = try std.fmt.allocPrint(
                allocator,
                "{s}/projects/{s}/regions/{s}/operations/{s}",
                .{ std.mem.trimEnd(u8, base_url, "/"), project_id, region, operation_name },
            ),
        };
    }

    pub fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        self.* = undefined;
    }
};

pub const Policy = struct {
    poll_interval_millis: u64 = 1_000,
    max_transient_failures: usize = 4,
};

pub const Result = struct {
    payload: []const u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

pub fn waitAlloc(
    client: *client_mod.Client,
    context: *provider.OperationContext,
    target: Target,
    policy: Policy,
) ProviderError!Result {
    var diagnostic = client_mod.Diagnostic.init(context.allocator);
    defer diagnostic.deinit();
    return waitWithDiagnosticAlloc(client, context, target, policy, &diagnostic);
}

pub fn waitWithDiagnosticAlloc(
    client: *client_mod.Client,
    context: *provider.OperationContext,
    target: Target,
    policy: Policy,
    diagnostic: *client_mod.Diagnostic,
) ProviderError!Result {
    var transient_failures: usize = 0;
    while (true) {
        try context.checkActive();
        var response = client.requestJsonAlloc(context, .{
            .method = "GET",
            .path = target.url,
        }, diagnostic) catch |err| {
            if ((err == error.TransientFailure or err == error.RateLimited) and
                transient_failures < policy.max_transient_failures)
            {
                transient_failures += 1;
                context.sleep(diagnostic.retry_after_millis orelse policy.poll_interval_millis);
                continue;
            }
            return err;
        };
        defer response.deinit(context.allocator);
        transient_failures = 0;

        const state = try inspectResponse(context.allocator, target.kind, response.body);
        if (state.failure) |failure| return failure;
        if (state.done) {
            return .{ .payload = context.allocator.dupe(u8, response.body) catch return error.OutOfMemory };
        }
        context.sleep(policy.poll_interval_millis);
    }
}

const PollState = struct {
    done: bool,
    failure: ?ProviderError = null,
};

fn inspectResponse(allocator: std.mem.Allocator, kind: Kind, body: []const u8) ProviderError!PollState {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.ProviderBug,
    };

    return switch (kind) {
        .generic => inspectGeneric(root),
        .compute_global, .compute_regional => inspectCompute(root),
    };
}

fn inspectGeneric(root: std.json.ObjectMap) PollState {
    const done = if (root.get("done")) |value| switch (value) {
        .bool => |present| present,
        else => false,
    } else false;
    if (!done) return .{ .done = false };
    if (root.get("error")) |error_value| {
        const error_object = switch (error_value) {
            .object => |object| object,
            else => return .{ .done = true, .failure = error.ProviderBug },
        };
        const code: u16 = if (error_object.get("code")) |value| switch (value) {
            .integer => |number| std.math.cast(u16, number) orelse 500,
            else => 500,
        } else 500;
        const status = if (error_object.get("status")) |value| switch (value) {
            .string => |text| text,
            else => null,
        } else null;
        return .{ .done = true, .failure = client_mod.classifyGoogleError(code, status, false) };
    }
    return .{ .done = true };
}

fn inspectCompute(root: std.json.ObjectMap) PollState {
    const status = if (root.get("status")) |value| switch (value) {
        .string => |text| text,
        else => return .{ .done = false },
    } else return .{ .done = false };
    if (!std.mem.eql(u8, status, "DONE")) return .{ .done = false };
    if (root.get("error") != null) return .{ .done = true, .failure = error.ProviderBug };
    return .{ .done = true };
}

fn joinUrlAlloc(allocator: std.mem.Allocator, base: []const u8, path: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ std.mem.trimEnd(u8, base, "/"), std.mem.trimStart(u8, path, "/") },
    );
}
