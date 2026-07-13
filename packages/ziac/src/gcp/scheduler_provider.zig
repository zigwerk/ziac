const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const job_type = "gcp.scheduler.Job";

pub const Handler = struct {
    client: *client_mod.Client,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const physical = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(physical);
        if (physical_override) |expected| if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .cloud_scheduler, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, physical, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const desired_url = try targetUrlAlloc(context, node);
        defer context.allocator.free(desired_url);
        const fields = [_]struct { input: []const u8, output: []const u8 }{
            .{ .input = "schedule", .output = "schedule" },
            .{ .input = "time_zone", .output = "time_zone" },
            .{ .input = "service_account", .output = "service_account" },
        };
        var changed = !std.mem.eql(u8, desired_url, outputString(observed, "uri") orelse "");
        for (fields) |field| changed = changed or !std.mem.eql(u8, try requiredString(node.inputs, field.input), outputString(observed, field.output) orelse "");
        return provider_mod.DiffResult.init(context.allocator, if (changed) .update else .noop, if (changed) &.{"Cloud Scheduler target or cadence differs"} else &.{});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}/locations/{s}/jobs", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location") });
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .cloud_scheduler, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        const physical = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(physical);
        return resultFromJson(context, node, physical, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask=schedule,timeZone,httpTarget,attemptDeadline,retryConfig", .{physical_id});
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .cloud_scheduler, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, physical_id, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const expected = try physicalIdAlloc(context.allocator, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .cloud_scheduler, .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, job_type);
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]u8 {
    const name = try physicalIdAlloc(context.allocator, node);
    defer context.allocator.free(name);
    const service_url = try resolveString(context, try requiredValue(node.inputs, "service_url"));
    const uri = try std.fmt.allocPrint(context.allocator, "{s}{s}", .{ std.mem.trimEnd(u8, service_url, "/"), try requiredString(node.inputs, "path") });
    defer context.allocator.free(uri);
    const deadline = try std.fmt.allocPrint(context.allocator, "{d}s", .{try requiredInteger(node.inputs, "attempt_deadline_seconds")});
    defer context.allocator.free(deadline);
    return std.json.Stringify.valueAlloc(context.allocator, .{
        .name = name,
        .description = "Ingest authoritative Ziac Cloud billing export",
        .schedule = try requiredString(node.inputs, "schedule"),
        .timeZone = try requiredString(node.inputs, "time_zone"),
        .attemptDeadline = deadline,
        .retryConfig = .{ .retryCount = 3, .minBackoffDuration = "30s", .maxBackoffDuration = "300s", .maxDoublings = 3 },
        .httpTarget = .{
            .uri = uri,
            .httpMethod = "POST",
            .body = "e30=",
            .oidcToken = .{ .serviceAccountEmail = try requiredString(node.inputs, "service_account"), .audience = service_url },
        },
    }, .{}) catch error.OutOfMemory;
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = object(parsed.value) orelse return error.ProviderBug;
    if (!std.mem.eql(u8, string(root.get("name")) orelse return error.ProviderBug, physical)) return error.InvalidConfiguration;
    const target = object(root.get("httpTarget") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const token = object(target.get("oidcToken") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "state", .value = .{ .string = string(root.get("state")) orelse "ENABLED" } },
        .{ .name = "schedule", .value = .{ .string = string(root.get("schedule")) orelse return error.ProviderBug } },
        .{ .name = "time_zone", .value = .{ .string = string(root.get("timeZone")) orelse return error.ProviderBug } },
        .{ .name = "uri", .value = .{ .string = string(target.get("uri")) orelse return error.ProviderBug } },
        .{ .name = "service_account", .value = .{ .string = string(token.get("serviceAccountEmail")) orelse return error.ProviderBug } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn targetUrlAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]u8 {
    const service_url = try resolveString(context, try requiredValue(node.inputs, "service_url"));
    return std.fmt.allocPrint(context.allocator, "{s}{s}", .{ std.mem.trimEnd(u8, service_url, "/"), try requiredString(node.inputs, "path") }) catch error.OutOfMemory;
}
fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/jobs/{s}", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location"), try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
}
fn outputString(result: *const provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .string => |text| text,
        else => null,
    };
    return null;
}
fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    if (input != .object) return error.InvalidConfiguration;
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(input, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}
fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |number| number,
        else => error.InvalidConfiguration,
    };
}
fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}
fn object(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |entry| entry,
        else => null,
    };
}
fn string(input: ?std.json.Value) ?[]const u8 {
    const present = input orelse return null;
    return switch (present) {
        .string => |entry| entry,
        else => null,
    };
}
