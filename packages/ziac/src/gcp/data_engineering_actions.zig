const std = @import("std");
const contract = @import("../agent_contract.zig");
const client_mod = @import("client.zig");
const provider = @import("../provider.zig");

pub const Action = enum {
    pipeline_run,
    pipeline_stop,
    dataflow_flex_launch,
    dataproc_cluster_start,
    dataproc_cluster_stop,
    dataproc_cluster_repair,
    dataproc_workflow_instantiate,
    dataform_compilation_create,
    dataform_workflow_invoke,
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };
pub const FlexLaunch = struct { job_name: []const u8, container_spec_gcs_path: []const u8, parameters: []const KeyValue = &.{} };
pub const ClusterRepair = struct { graceful_decommission_timeout_seconds: u32 = 0 };
pub const DataformCompilation = struct { git_commitish: []const u8 };
pub const DataformInvocation = struct { compilation_result: []const u8 };
pub const Payload = union(enum) {
    none: void,
    dataflow_flex: FlexLaunch,
    cluster_repair: ClusterRepair,
    dataform_compilation: DataformCompilation,
    dataform_invocation: DataformInvocation,
};

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
    previous_state: []const u8,
    status: []const u8,
    action_digest: []const u8,

    pub fn deinit(self: *Receipt) void {
        self.allocator.free(self.resource_name);
        self.allocator.free(self.result_name);
        self.allocator.free(self.previous_state);
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
            .action = authority.action,
            .creates = authority.creates,
            .updates = authority.updates,
            .deletes = authority.deletes,
            .regions = 1,
            .plan_digest = digest,
        });

        var previous_state: []const u8 = "NOT_APPLICABLE";
        var owned_previous_state: ?[]u8 = null;
        defer if (owned_previous_state) |owned| context.allocator.free(owned);
        if (requiresStateRead(action)) {
            const read_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{target.resource_name});
            defer context.allocator.free(read_path);
            var before_response = try self.request(context, apiFor(action), "GET", read_path, "");
            defer before_response.deinit(context.allocator);
            var before = try std.json.parseFromSlice(std.json.Value, context.allocator, before_response.body, .{});
            defer before.deinit();
            const root = jsonObject(before.value) orelse return error.ProviderBug;
            const observed_state = if (isPipeline(action))
                jsonString(root.get("state")) orelse return error.ProviderBug
            else if (jsonObject(root.get("status") orelse .null)) |status|
                jsonString(status.get("state")) orelse return error.ProviderBug
            else
                return error.ProviderBug;
            owned_previous_state = try context.allocator.dupe(u8, observed_state);
            previous_state = owned_previous_state.?;
            try validateTransition(action, previous_state);
        }

        const body = try bodyAlloc(context.allocator, action, payload);
        defer context.allocator.free(body);
        const path = try actionPathAlloc(context.allocator, action, target);
        defer context.allocator.free(path);
        var response = try self.request(context, apiFor(action), "POST", path, body);
        defer response.deinit(context.allocator);
        const result_name = try resultNameAlloc(context.allocator, action, response.body);
        defer context.allocator.free(result_name);
        return .{
            .allocator = context.allocator,
            .action = action,
            .resource_name = try context.allocator.dupe(u8, target.resource_name),
            .result_name = try context.allocator.dupe(u8, result_name),
            .previous_state = try context.allocator.dupe(u8, previous_state),
            .status = try context.allocator.dupe(u8, statusFor(action)),
            .action_digest = try context.allocator.dupe(u8, digest),
        };
    }

    fn request(self: Runner, context: *provider.OperationContext, api: client_mod.Api, method: []const u8, path: []const u8, body: []const u8) !@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = api, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

const Authority = struct { action: contract.Action, creates: usize = 0, updates: usize = 0, deletes: usize = 0 };
fn authorityFor(action: Action) Authority {
    return switch (action) {
        .pipeline_stop => .{ .action = .delete, .deletes = 1 },
        .dataproc_cluster_start, .dataproc_cluster_stop, .dataproc_cluster_repair => .{ .action = .apply, .updates = 1 },
        else => .{ .action = .apply, .creates = 1 },
    };
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
        .dataflow_flex => |args| {
            digestField(&hasher, args.job_name);
            digestField(&hasher, args.container_spec_gcs_path);
            for (args.parameters) |item| {
                digestField(&hasher, item.key);
                digestField(&hasher, item.value);
            }
        },
        .cluster_repair => |args| {
            var number: [4]u8 = undefined;
            std.mem.writeInt(u32, &number, args.graceful_decommission_timeout_seconds, .little);
            hasher.update(&number);
        },
        .dataform_compilation => |args| digestField(&hasher, args.git_commitish),
        .dataform_invocation => |args| digestField(&hasher, args.compilation_result),
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
    const valid_segment = switch (action) {
        .pipeline_run, .pipeline_stop => "/pipelines/",
        .dataflow_flex_launch => "/flexTemplates/",
        .dataproc_cluster_start, .dataproc_cluster_stop, .dataproc_cluster_repair => "/clusters/",
        .dataproc_workflow_instantiate => "/workflowTemplates/",
        .dataform_compilation_create, .dataform_workflow_invoke => "/repositories/",
    };
    if (std.mem.indexOf(u8, target.resource_name, valid_segment) == null) return error.InvalidActionTarget;
    const expected_payload: std.meta.Tag(Payload) = switch (action) {
        .pipeline_run, .pipeline_stop, .dataproc_cluster_start, .dataproc_cluster_stop, .dataproc_workflow_instantiate => .none,
        .dataflow_flex_launch => .dataflow_flex,
        .dataproc_cluster_repair => .cluster_repair,
        .dataform_compilation_create => .dataform_compilation,
        .dataform_workflow_invoke => .dataform_invocation,
    };
    if (std.meta.activeTag(payload) != expected_payload) return error.InvalidActionPayload;
    switch (payload) {
        .dataflow_flex => |args| if (args.job_name.len == 0 or !std.mem.startsWith(u8, args.container_spec_gcs_path, "gs://")) return error.InvalidActionPayload,
        .dataform_compilation => |args| if (args.git_commitish.len == 0) return error.InvalidActionPayload,
        .dataform_invocation => |args| if (std.mem.indexOf(u8, args.compilation_result, "/compilationResults/") == null) return error.InvalidActionPayload,
        else => {},
    }
}

fn validateTransition(action: Action, state: []const u8) !void {
    const valid = switch (action) {
        .pipeline_run => std.mem.eql(u8, state, "STATE_ACTIVE"),
        .pipeline_stop => std.mem.eql(u8, state, "STATE_ACTIVE"),
        .dataproc_cluster_start => std.mem.eql(u8, state, "STOPPED"),
        .dataproc_cluster_stop, .dataproc_cluster_repair => std.mem.eql(u8, state, "RUNNING"),
        else => true,
    };
    if (!valid) return error.InvalidResourceState;
}

fn actionPathAlloc(allocator: std.mem.Allocator, action: Action, target: Target) ![]u8 {
    return switch (action) {
        .pipeline_run => std.fmt.allocPrint(allocator, "/v1/{s}:run", .{target.resource_name}),
        .pipeline_stop => std.fmt.allocPrint(allocator, "/v1/{s}:stop", .{target.resource_name}),
        .dataflow_flex_launch => blk: {
            const location = try scopeSegment(target.resource_name, "locations");
            break :blk std.fmt.allocPrint(allocator, "/v1b3/projects/{s}/locations/{s}/flexTemplates:launch", .{ target.project, location });
        },
        .dataproc_cluster_start => std.fmt.allocPrint(allocator, "/v1/{s}:start", .{target.resource_name}),
        .dataproc_cluster_stop => std.fmt.allocPrint(allocator, "/v1/{s}:stop", .{target.resource_name}),
        .dataproc_cluster_repair => std.fmt.allocPrint(allocator, "/v1/{s}:repair", .{target.resource_name}),
        .dataproc_workflow_instantiate => std.fmt.allocPrint(allocator, "/v1/{s}:instantiate", .{target.resource_name}),
        .dataform_compilation_create => std.fmt.allocPrint(allocator, "/v1beta1/{s}/compilationResults", .{target.resource_name}),
        .dataform_workflow_invoke => std.fmt.allocPrint(allocator, "/v1beta1/{s}/workflowInvocations", .{target.resource_name}),
    } catch error.OutOfMemory;
}

fn bodyAlloc(allocator: std.mem.Allocator, action: Action, payload: Payload) ![]u8 {
    _ = action;
    return switch (payload) {
        .none => allocator.dupe(u8, "{}"),
        .cluster_repair => |args| if (args.graceful_decommission_timeout_seconds == 0)
            allocator.dupe(u8, "{}")
        else
            std.fmt.allocPrint(allocator, "{{\"gracefulDecommissionTimeout\":\"{d}s\"}}", .{args.graceful_decommission_timeout_seconds}),
        .dataform_compilation => |args| std.json.Stringify.valueAlloc(allocator, .{ .gitCommitish = args.git_commitish }, .{}),
        .dataform_invocation => |args| std.json.Stringify.valueAlloc(allocator, .{ .compilationResult = args.compilation_result }, .{}),
        .dataflow_flex => |args| blk: {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var parameters = std.json.ObjectMap.empty;
            for (args.parameters) |item| try parameters.put(arena, item.key, .{ .string = item.value });
            var launch = std.json.ObjectMap.empty;
            try launch.put(arena, "jobName", .{ .string = args.job_name });
            try launch.put(arena, "containerSpecGcsPath", .{ .string = args.container_spec_gcs_path });
            try launch.put(arena, "parameters", .{ .object = parameters });
            var root = std.json.ObjectMap.empty;
            try root.put(arena, "launchParameter", .{ .object = launch });
            break :blk try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{});
        },
    } catch error.OutOfMemory;
}

fn resultNameAlloc(allocator: std.mem.Allocator, action: Action, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    if (jsonString(root.get("name"))) |name| return allocator.dupe(u8, name);
    if (jsonObject(root.get("job") orelse .null)) |job| {
        if (jsonString(job.get("name")) orelse jsonString(job.get("id"))) |name| return allocator.dupe(u8, name);
    }
    _ = action;
    return error.ProviderBug;
}

fn apiFor(action: Action) client_mod.Api {
    return switch (action) {
        .pipeline_run, .pipeline_stop => .data_pipelines,
        .dataflow_flex_launch => .dataflow,
        .dataproc_cluster_start, .dataproc_cluster_stop, .dataproc_cluster_repair, .dataproc_workflow_instantiate => .dataproc,
        .dataform_compilation_create, .dataform_workflow_invoke => .dataform,
    };
}
fn requiresStateRead(action: Action) bool {
    return isPipeline(action) or action == .dataproc_cluster_start or action == .dataproc_cluster_stop or action == .dataproc_cluster_repair;
}
fn isPipeline(action: Action) bool {
    return action == .pipeline_run or action == .pipeline_stop;
}
fn statusFor(action: Action) []const u8 {
    return switch (action) {
        .dataform_compilation_create => "CREATED",
        .dataform_workflow_invoke, .pipeline_run, .dataflow_flex_launch => "RUNNING",
        else => "OPERATION_PENDING",
    };
}
fn scopeSegment(resource_name: []const u8, marker: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, resource_name, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, marker)) return parts.next() orelse error.InvalidActionTarget;
    return error.InvalidActionTarget;
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
