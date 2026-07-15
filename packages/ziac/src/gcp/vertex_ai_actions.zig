const std = @import("std");
const contract = @import("../agent_contract.zig");
const client_mod = @import("client.zig");
const provider = @import("../provider.zig");

pub const Action = enum {
    model_deploy,
    model_undeploy,
    index_deploy,
    index_undeploy,
    pipeline_submit,
    pipeline_cancel,
    feature_view_sync,
};

pub const ModelDeploymentIntent = struct {
    deployed_model_id: []const u8,
    machine_type: []const u8,
    min_replicas: u16,
    max_replicas: u16,
};
pub const IndexDeploymentIntent = struct {
    deployed_index_id: []const u8,
};
pub const ModelDeployment = struct {
    deployed_model_id: []const u8,
    display_name: []const u8,
    model: []const u8,
    machine_type: []const u8,
    min_replicas: u16,
    max_replicas: u16,
};
pub const IndexDeployment = struct {
    deployed_index_id: []const u8,
    display_name: []const u8,
    index: []const u8,
};
pub const Undeployment = struct { deployed_resource_id: []const u8 };
pub const PipelineJob = struct {
    display_name: []const u8,
    template_uri: []const u8,
    runtime_config_json: []const u8 = "{}",
};
pub const Payload = union(enum) {
    none: void,
    model_deployment: ModelDeployment,
    index_deployment: IndexDeployment,
    undeployment: Undeployment,
    pipeline_job: PipelineJob,
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
        const location = try validateTarget(action, target, payload);
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
        const path = try actionPathAlloc(context.allocator, action, target);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context.allocator, action, payload);
        defer context.allocator.free(body);
        var response = try self.request(context, location, "POST", path, body);
        defer response.deinit(context.allocator);
        const result_name = try resultNameAlloc(context.allocator, target.resource_name, response.body);
        defer context.allocator.free(result_name);
        return .{
            .allocator = context.allocator,
            .action = action,
            .resource_name = try context.allocator.dupe(u8, target.resource_name),
            .result_name = try context.allocator.dupe(u8, result_name),
            .status = try context.allocator.dupe(u8, statusFor(action)),
            .action_digest = try context.allocator.dupe(u8, digest),
        };
    }

    fn request(self: Runner, context: *provider.OperationContext, location: []const u8, method: []const u8, path: []const u8, body: []const u8) !@import("zigeffect_std").Http.Response {
        const base = try regionalBaseAlloc(context.allocator, self.client.endpoints.vertex_ai, location);
        defer context.allocator.free(base);
        const url = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), std.mem.trimStart(u8, path, "/") });
        defer context.allocator.free(url);
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .method = method, .path = url, .body = body }, &diagnostic);
    }
};

const Authority = struct { action: contract.Action, creates: usize = 0, updates: usize = 0, deletes: usize = 0 };
fn authorityFor(action: Action) Authority {
    return switch (action) {
        .pipeline_submit => .{ .action = .apply, .creates = 1 },
        .model_undeploy, .index_undeploy, .pipeline_cancel => .{ .action = .delete, .deletes = 1 },
        .model_deploy, .index_deploy, .feature_view_sync => .{ .action = .apply, .updates = 1 },
    };
}

pub fn validateModelDeploymentIntent(intent: ModelDeploymentIntent) !void {
    if (!validId(intent.deployed_model_id) or intent.machine_type.len == 0 or intent.min_replicas == 0 or intent.max_replicas < intent.min_replicas) return error.InvalidActionPayload;
}
pub fn validateIndexDeploymentIntent(intent: IndexDeploymentIntent) !void {
    if (!validId(intent.deployed_index_id)) return error.InvalidActionPayload;
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
        .model_deployment => |item| {
            digestField(&hasher, item.deployed_model_id);
            digestField(&hasher, item.display_name);
            digestField(&hasher, item.model);
            digestField(&hasher, item.machine_type);
            digestNumber(&hasher, item.min_replicas);
            digestNumber(&hasher, item.max_replicas);
        },
        .index_deployment => |item| {
            digestField(&hasher, item.deployed_index_id);
            digestField(&hasher, item.display_name);
            digestField(&hasher, item.index);
        },
        .undeployment => |item| digestField(&hasher, item.deployed_resource_id),
        .pipeline_job => |item| {
            digestField(&hasher, item.display_name);
            digestField(&hasher, item.template_uri);
            digestField(&hasher, item.runtime_config_json);
        },
    }
    var bytes: [32]u8 = undefined;
    hasher.final(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn validateTarget(action: Action, target: Target, payload: Payload) ![]const u8 {
    if (target.stage.len == 0 or target.project.len == 0 or target.resource_name.len == 0 or std.mem.indexOfAny(u8, target.resource_name, "?# \t\r\n") != null) return error.InvalidActionTarget;
    const prefix = try std.fmt.allocPrint(std.heap.page_allocator, "projects/{s}/locations/", .{target.project});
    defer std.heap.page_allocator.free(prefix);
    if (!std.mem.startsWith(u8, target.resource_name, prefix)) return error.InvalidActionTarget;
    const location_tail = target.resource_name[prefix.len..];
    const location_end = std.mem.indexOfScalar(u8, location_tail, '/') orelse location_tail.len;
    const location = location_tail[0..location_end];
    if (location.len == 0 or std.mem.indexOfAny(u8, location, ".:@/ \t\r\n") != null) return error.InvalidActionTarget;
    const expected_payload: std.meta.Tag(Payload) = switch (action) {
        .model_deploy => .model_deployment,
        .index_deploy => .index_deployment,
        .model_undeploy, .index_undeploy => .undeployment,
        .pipeline_submit => .pipeline_job,
        .pipeline_cancel, .feature_view_sync => .none,
    };
    if (std.meta.activeTag(payload) != expected_payload) return error.InvalidActionPayload;
    const segment_valid = switch (action) {
        .model_deploy, .model_undeploy => std.mem.indexOf(u8, target.resource_name, "/endpoints/") != null,
        .index_deploy, .index_undeploy => std.mem.indexOf(u8, target.resource_name, "/indexEndpoints/") != null,
        .pipeline_submit => location_end == location_tail.len,
        .pipeline_cancel => std.mem.indexOf(u8, target.resource_name, "/pipelineJobs/") != null,
        .feature_view_sync => std.mem.indexOf(u8, target.resource_name, "/featureOnlineStores/") != null and std.mem.indexOf(u8, target.resource_name, "/featureViews/") != null,
    };
    if (!segment_valid) return error.InvalidActionTarget;
    switch (payload) {
        .model_deployment => |item| {
            try validateModelDeploymentIntent(.{ .deployed_model_id = item.deployed_model_id, .machine_type = item.machine_type, .min_replicas = item.min_replicas, .max_replicas = item.max_replicas });
            if (item.display_name.len == 0 or std.mem.indexOf(u8, item.model, "/models/") == null) return error.InvalidActionPayload;
        },
        .index_deployment => |item| {
            try validateIndexDeploymentIntent(.{ .deployed_index_id = item.deployed_index_id });
            if (item.display_name.len == 0 or std.mem.indexOf(u8, item.index, "/indexes/") == null) return error.InvalidActionPayload;
        },
        .undeployment => |item| if (!validId(item.deployed_resource_id)) return error.InvalidActionPayload,
        .pipeline_job => |item| {
            if (item.display_name.len == 0 or (!std.mem.startsWith(u8, item.template_uri, "https://") and !std.mem.startsWith(u8, item.template_uri, "gs://"))) return error.InvalidActionPayload;
            var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, item.runtime_config_json, .{}) catch return error.InvalidActionPayload;
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidActionPayload;
        },
        .none => {},
    }
    return location;
}

fn actionPathAlloc(allocator: std.mem.Allocator, action: Action, target: Target) ![]u8 {
    return switch (action) {
        .model_deploy => std.fmt.allocPrint(allocator, "/v1/{s}:deployModel", .{target.resource_name}),
        .model_undeploy => std.fmt.allocPrint(allocator, "/v1/{s}:undeployModel", .{target.resource_name}),
        .index_deploy => std.fmt.allocPrint(allocator, "/v1/{s}:deployIndex", .{target.resource_name}),
        .index_undeploy => std.fmt.allocPrint(allocator, "/v1/{s}:undeployIndex", .{target.resource_name}),
        .pipeline_submit => std.fmt.allocPrint(allocator, "/v1/{s}/pipelineJobs", .{target.resource_name}),
        .pipeline_cancel => std.fmt.allocPrint(allocator, "/v1/{s}:cancel", .{target.resource_name}),
        .feature_view_sync => std.fmt.allocPrint(allocator, "/v1/{s}:sync", .{target.resource_name}),
    };
}

fn bodyAlloc(allocator: std.mem.Allocator, action: Action, payload: Payload) ![]u8 {
    _ = action;
    return switch (payload) {
        .none => allocator.dupe(u8, "{}"),
        .undeployment => |item| std.json.Stringify.valueAlloc(allocator, .{ .deployedResourceId = item.deployed_resource_id }, .{}),
        .index_deployment => |item| std.json.Stringify.valueAlloc(allocator, .{ .deployedIndex = .{ .id = item.deployed_index_id, .displayName = item.display_name, .index = item.index } }, .{}),
        .model_deployment => |item| std.json.Stringify.valueAlloc(allocator, .{
            .deployedModel = .{
                .id = item.deployed_model_id,
                .displayName = item.display_name,
                .model = item.model,
                .dedicatedResources = .{
                    .machineSpec = .{ .machineType = item.machine_type },
                    .minReplicaCount = item.min_replicas,
                    .maxReplicaCount = item.max_replicas,
                },
            },
        }, .{}),
        .pipeline_job => |item| blk: {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var runtime = std.json.parseFromSlice(std.json.Value, arena, item.runtime_config_json, .{}) catch return error.InvalidActionPayload;
            defer runtime.deinit();
            var root = std.json.ObjectMap.empty;
            try root.put(arena, "displayName", .{ .string = item.display_name });
            try root.put(arena, "templateUri", .{ .string = item.template_uri });
            try root.put(arena, "runtimeConfig", runtime.value);
            break :blk try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{});
        },
    };
}

fn resultNameAlloc(allocator: std.mem.Allocator, fallback: []const u8, body: []const u8) ![]u8 {
    if (body.len != 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        if (parsed.value == .object) if (parsed.value.object.get("name")) |name| if (name == .string) return allocator.dupe(u8, name.string);
    }
    return allocator.dupe(u8, fallback);
}
fn statusFor(action: Action) []const u8 {
    return switch (action) {
        .pipeline_submit => "SUBMITTED",
        .pipeline_cancel => "CANCEL_REQUESTED",
        .feature_view_sync => "SYNC_REQUESTED",
        else => "OPERATION_PENDING",
    };
}
fn regionalBaseAlloc(allocator: std.mem.Allocator, base: []const u8, location: []const u8) ![]u8 {
    const prefix = "https://";
    if (!std.mem.startsWith(u8, base, prefix)) return error.InvalidActionTarget;
    const host = std.mem.trimEnd(u8, base[prefix.len..], "/");
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '/') != null) return error.InvalidActionTarget;
    return std.fmt.allocPrint(allocator, "https://{s}-{s}", .{ location, host });
}
fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128 or !std.ascii.isAlphanumeric(id[0])) return false;
    for (id) |character| if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') return false;
    return true;
}
fn digestField(hasher: *std.crypto.hash.sha2.Sha256, field: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, field.len, .little);
    hasher.update(&length);
    hasher.update(field);
}
fn digestNumber(hasher: *std.crypto.hash.sha2.Sha256, number: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, number, .little);
    hasher.update(&bytes);
}
