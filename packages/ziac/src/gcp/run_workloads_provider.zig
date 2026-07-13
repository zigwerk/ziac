const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const rpc = @import("rpc.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const job_type = "gcp.run.Job";
const worker_pool_type = "gcp.run.WorkerPool";
const worker_update_mask = "description,labels,annotations,template,instanceSplits,scaling";

const Kind = enum { job, worker_pool };

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const kind = try kindFor(node);
        if (context.operation_handle) |handle| {
            if (try self.waitForResource(context, kind, node, handle)) |result| return .{ .present = result };
        }
        const expected = try physicalIdAlloc(context.allocator, node, kind);
        defer context.allocator.free(expected);
        const physical = physical_override orelse expected;
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        const method = getMethod(kind);
        const path = try rpcPathAlloc(context, method, &.{.{ .field = "name", .value = physical }}, &.{});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .run, .method = method.rest.?.method.text(), .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const changed = !std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash);
        if (!changed) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        for ([_][]const u8{ "project_id", "region", "name" }) |field| {
            const desired = inputString(node.inputs, field) orelse return error.InvalidConfiguration;
            const remote = inputString(observed.observed_inputs, field) orelse return error.InvalidConfiguration;
            if (!std.mem.eql(u8, desired, remote)) return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Cloud Run workload identity changed"});
        }
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Cloud Run workload configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const kind = try kindFor(node);
        const parent = try std.fmt.allocPrint(context.allocator, "projects/{s}/locations/{s}", .{
            try requiredString(node.inputs, "project_id"),
            try requiredString(node.inputs, "region"),
        });
        defer context.allocator.free(parent);
        const method = createMethod(kind);
        const id_field = if (kind == .job) "job_id" else "worker_pool_id";
        const path = try rpcPathAlloc(context, method, &.{.{ .field = "parent", .value = parent }}, &.{
            .{ .field = id_field, .value = try requiredString(node.inputs, "name") },
            .{ .field = "validate_only", .value = "false" },
        });
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind, null);
        defer context.allocator.free(body);
        const handle = try self.startOperation(context, method, path, body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, kind, handle);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const kind = try kindFor(node);
        const etag = outputString(observed, "etag") orelse return error.Conflict;
        const method = updateMethod(kind);
        const routing_field = if (kind == .job) "job.name" else "worker_pool.name";
        const query: []const rpc.Parameter = if (kind == .job)
            &.{
                .{ .field = "validate_only", .value = "false" },
                .{ .field = "allow_missing", .value = "false" },
            }
        else
            &.{
                .{ .field = "update_mask", .value = worker_update_mask },
                .{ .field = "validate_only", .value = "false" },
                .{ .field = "allow_missing", .value = "false" },
                .{ .field = "force_new_revision", .value = "false" },
            };
        const path = try rpcPathAlloc(context, method, &.{.{ .field = routing_field, .value = observed.physical_id }}, query);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind, etag);
        defer context.allocator.free(body);
        const handle = try self.startOperation(context, method, path, body);
        defer context.allocator.free(handle);
        return pendingResult(context, node, kind, handle);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const kind = try kindFor(node);
        const expected = try physicalIdAlloc(context.allocator, node, kind);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const get_method = getMethod(kind);
        const get_path = try rpcPathAlloc(context, get_method, &.{.{ .field = "name", .value = physical_id }}, &.{});
        defer context.allocator.free(get_path);
        var current = self.request(context, .{ .api = .run, .method = "GET", .path = get_path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer current.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, current.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const etag = jsonString(root.get("etag")) orelse return error.Conflict;
        const method = deleteMethod(kind);
        const path = try rpcPathAlloc(context, method, &.{.{ .field = "name", .value = physical_id }}, &.{
            .{ .field = "validate_only", .value = "false" },
            .{ .field = "etag", .value = etag },
        });
        defer context.allocator.free(path);
        const handle = self.startOperation(context, method, path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(handle);
        _ = try self.waitForResource(context, kind, null, handle);
    }

    fn startOperation(self: Handler, context: *provider_mod.OperationContext, method: rpc.Method, path: []const u8, body: []const u8) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = .run, .method = method.rest.?.method.text(), .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, jsonString(root.get("name")) orelse return error.ProviderBug) catch error.OutOfMemory;
    }

    fn waitForResource(self: Handler, context: *provider_mod.OperationContext, kind: Kind, maybe_node: ?resource.ResourceNode, handle: []const u8) ProviderError!?provider_mod.ResourceResult {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v2", .{std.mem.trimEnd(u8, self.client.endpoints.run, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        defer completed.deinit(context.allocator);
        const node = maybe_node orelse return null;
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, completed.payload, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const response_value = root.get("response") orelse return error.ProviderBug;
        const body = std.json.Stringify.valueAlloc(context.allocator, response_value, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        return try resultFromJson(context, node, kind, body);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, job_type) or std.mem.eql(u8, node.type_name, worker_pool_type);
}

fn kindFor(node: resource.ResourceNode) ProviderError!Kind {
    if (std.mem.eql(u8, node.type_name, job_type)) return .job;
    if (std.mem.eql(u8, node.type_name, worker_pool_type)) return .worker_pool;
    return error.InvalidConfiguration;
}

fn createMethod(kind: Kind) rpc.Method {
    return if (kind == .job) rpc.cloud_run_v2.create_job else rpc.cloud_run_v2.create_worker_pool;
}
fn getMethod(kind: Kind) rpc.Method {
    return if (kind == .job) rpc.cloud_run_v2.get_job else rpc.cloud_run_v2.get_worker_pool;
}
fn updateMethod(kind: Kind) rpc.Method {
    return if (kind == .job) rpc.cloud_run_v2.update_job else rpc.cloud_run_v2.update_worker_pool;
}
fn deleteMethod(kind: Kind) rpc.Method {
    return if (kind == .job) rpc.cloud_run_v2.delete_job else rpc.cloud_run_v2.delete_worker_pool;
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, etag: ?[]const u8) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var body: std.json.ObjectMap = .empty;
    const physical = try physicalIdAlloc(arena, node, kind);
    if (etag != null) try body.put(arena, "name", .{ .string = physical });
    if (kind == .worker_pool) try body.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
    try body.put(arena, "labels", try plainValueToJson(arena, try requiredValue(node.inputs, "labels")));
    try body.put(arena, "annotations", try plainValueToJson(arena, try requiredValue(node.inputs, "annotations")));
    try body.put(arena, "template", try templateRequestJson(context, arena, node, kind));
    if (kind == .worker_pool) {
        var scaling: std.json.ObjectMap = .empty;
        try scaling.put(arena, "manualInstanceCount", .{ .integer = try requiredInteger(node.inputs, "manual_instance_count") });
        try body.put(arena, "scaling", .{ .object = scaling });
        try body.put(arena, "instanceSplits", try splitsRequestJson(arena, try requiredValue(node.inputs, "instance_splits")));
        const revision = try requiredString(node.inputs, "revision");
        if (revision.len > 0) try body.put(arena, "revision", .{ .string = revision });
    }
    if (etag) |present| try body.put(arena, "etag", .{ .string = present });
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = body }, .{}) catch error.OutOfMemory;
}

fn templateRequestJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError!std.json.Value {
    var task: std.json.ObjectMap = .empty;
    try task.put(arena, "containers", try containersRequestJson(context, arena, node.inputs));
    try task.put(arena, "volumes", try volumesRequestJson(arena, try requiredValue(node.inputs, "secret_volumes")));
    try task.put(arena, "serviceAccount", .{ .string = try requiredString(node.inputs, "service_account") });
    const encryption = try requiredString(node.inputs, "encryption_key");
    if (encryption.len > 0) try task.put(arena, "encryptionKey", .{ .string = encryption });
    if (try vpcRequestJson(context, arena, try requiredValue(node.inputs, "vpc_access"))) |vpc| try task.put(arena, "vpcAccess", vpc);
    const accelerator = try requiredString(node.inputs, "gpu_accelerator");
    if (accelerator.len > 0) {
        var selector: std.json.ObjectMap = .empty;
        try selector.put(arena, "accelerator", .{ .string = accelerator });
        try task.put(arena, "nodeSelector", .{ .object = selector });
    }
    if (try requiredBool(node.inputs, "gpu_zonal_redundancy_disabled")) try task.put(arena, "gpuZonalRedundancyDisabled", .{ .bool = true });
    if (kind == .job) {
        try task.put(arena, "maxRetries", .{ .integer = try requiredInteger(node.inputs, "max_retries") });
        const timeout = try std.fmt.allocPrint(arena, "{d}s", .{try requiredInteger(node.inputs, "timeout_seconds")});
        try task.put(arena, "timeout", .{ .string = timeout });
        try task.put(arena, "executionEnvironment", .{ .string = try requiredString(node.inputs, "execution_environment") });
        var execution: std.json.ObjectMap = .empty;
        try execution.put(arena, "taskCount", .{ .integer = try requiredInteger(node.inputs, "task_count") });
        try execution.put(arena, "parallelism", .{ .integer = try requiredInteger(node.inputs, "parallelism") });
        try execution.put(arena, "template", .{ .object = task });
        return .{ .object = execution };
    }
    return .{ .object = task };
}

fn containersRequestJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, inputs: value.Value) ProviderError!std.json.Value {
    const containers = try requiredList(inputs, "containers");
    const volumes = try requiredList(inputs, "secret_volumes");
    var result = std.json.Array.init(arena);
    for (containers, 0..) |container, container_index| {
        var encoded: std.json.ObjectMap = .empty;
        const name = try requiredString(container, "name");
        try encoded.put(arena, "name", .{ .string = name });
        try encoded.put(arena, "image", .{ .string = try resolveString(context, try requiredValue(container, "image")) });
        const command = try requiredValue(container, "command");
        if ((try requiredListValue(command)).len > 0) try encoded.put(arena, "command", try stringListJson(arena, command));
        const args = try requiredValue(container, "args");
        if ((try requiredListValue(args)).len > 0) try encoded.put(arena, "args", try stringListJson(arena, args));
        const env = try requiredValue(container, "env");
        if ((try requiredListValue(env)).len > 0) try encoded.put(arena, "env", try envRequestJson(context, arena, env));
        var limits: std.json.ObjectMap = .empty;
        try limits.put(arena, "cpu", .{ .string = try requiredString(container, "cpu") });
        try limits.put(arena, "memory", .{ .string = try requiredString(container, "memory") });
        var resources: std.json.ObjectMap = .empty;
        try resources.put(arena, "limits", .{ .object = limits });
        try encoded.put(arena, "resources", .{ .object = resources });
        var mounts = std.json.Array.init(arena);
        for (volumes) |volume| {
            const explicit = try requiredString(volume, "container");
            const target = if (explicit.len > 0) explicit else if (containers.len == 1) name else return error.InvalidConfiguration;
            if (!std.mem.eql(u8, target, name)) continue;
            var mount: std.json.ObjectMap = .empty;
            try mount.put(arena, "name", .{ .string = try requiredString(volume, "name") });
            try mount.put(arena, "mountPath", .{ .string = try requiredString(volume, "mount_path") });
            try mounts.append(.{ .object = mount });
        }
        if (mounts.items.len > 0) try encoded.put(arena, "volumeMounts", .{ .array = mounts });
        _ = container_index;
        try result.append(.{ .object = encoded });
    }
    return .{ .array = result };
}

fn envRequestJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var result = std.json.Array.init(arena);
    for (try requiredListValue(input)) |item| {
        var encoded: std.json.ObjectMap = .empty;
        try encoded.put(arena, "name", .{ .string = try requiredString(item, "name") });
        if (try requiredBool(item, "secret")) {
            const reference = try resolveSecret(context, try requiredValue(item, "value"));
            var selector: std.json.ObjectMap = .empty;
            try selector.put(arena, "secret", .{ .string = reference.resource });
            try selector.put(arena, "version", .{ .string = reference.version orelse "latest" });
            var source: std.json.ObjectMap = .empty;
            try source.put(arena, "secretKeyRef", .{ .object = selector });
            try encoded.put(arena, "valueSource", .{ .object = source });
        } else try encoded.put(arena, "value", .{ .string = try resolveString(context, try requiredValue(item, "value")) });
        try result.append(.{ .object = encoded });
    }
    return .{ .array = result };
}

fn volumesRequestJson(arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var result = std.json.Array.init(arena);
    for (try requiredListValue(input)) |item| {
        const reference = try requiredSecret(item, "secret");
        var key: std.json.ObjectMap = .empty;
        try key.put(arena, "version", .{ .string = reference.version orelse "latest" });
        try key.put(arena, "path", .{ .string = try requiredString(item, "path") });
        var keys = std.json.Array.init(arena);
        try keys.append(.{ .object = key });
        var secret: std.json.ObjectMap = .empty;
        try secret.put(arena, "secret", .{ .string = reference.resource });
        try secret.put(arena, "items", .{ .array = keys });
        var encoded: std.json.ObjectMap = .empty;
        try encoded.put(arena, "name", .{ .string = try requiredString(item, "name") });
        try encoded.put(arena, "secret", .{ .object = secret });
        try result.append(.{ .object = encoded });
    }
    return .{ .array = result };
}

fn splitsRequestJson(arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var result = std.json.Array.init(arena);
    for (try requiredListValue(input)) |item| {
        var split: std.json.ObjectMap = .empty;
        try split.put(arena, "type", .{ .string = try requiredString(item, "allocation") });
        try split.put(arena, "percent", .{ .integer = try requiredInteger(item, "percent") });
        const revision = try requiredString(item, "revision");
        if (revision.len > 0) try split.put(arena, "revision", .{ .string = revision });
        try result.append(.{ .object = split });
    }
    return .{ .array = result };
}

fn vpcRequestJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, input: value.Value) ProviderError!?std.json.Value {
    const fields = try requiredObjectValue(input);
    if (fields.len == 0) return null;
    var interface: std.json.ObjectMap = .empty;
    try interface.put(arena, "network", .{ .string = try resolveString(context, try requiredValue(input, "network")) });
    try interface.put(arena, "subnetwork", .{ .string = try resolveString(context, try requiredValue(input, "subnetwork")) });
    try interface.put(arena, "tags", try stringListJson(arena, try requiredValue(input, "tags")));
    var interfaces = std.json.Array.init(arena);
    try interfaces.append(.{ .object = interface });
    var vpc: std.json.ObjectMap = .empty;
    try vpc.put(arena, "egress", .{ .string = try requiredString(input, "egress") });
    try vpc.put(arena, "networkInterfaces", .{ .array = interfaces });
    return .{ .object = vpc };
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    const etag = jsonString(root.get("etag")) orelse return error.ProviderBug;
    var observed = try normalizedInputs(context, node, kind, root);
    defer observed.deinit(context.allocator);
    const uid = jsonString(root.get("uid")) orelse "";
    const ready = !jsonBool(root.get("reconciling"), false) and conditionSucceeded(root.get("terminalCondition"));
    if (kind == .job) {
        const latest = if (jsonObjectOptional(root.get("latestCreatedExecution"))) |execution| jsonString(execution.get("name")) orelse "" else "";
        const outputs = [_]state.StateOutput{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "uid", .value = .{ .string = uid } },
            .{ .name = "execution_count", .value = .{ .integer = jsonInt64(root.get("executionCount")) orelse 0 } },
            .{ .name = "latest_execution", .value = .{ .string = latest } },
            .{ .name = "ready", .value = .{ .boolean = ready } },
            .{ .name = "etag", .value = .{ .string = etag } },
        };
        return provider_mod.ResourceResult.init(context.allocator, physical, observed, &outputs, null);
    }
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "uid", .value = .{ .string = uid } },
        .{ .name = "latest_ready_revision", .value = .{ .string = jsonString(root.get("latestReadyRevision")) orelse "" } },
        .{ .name = "latest_created_revision", .value = .{ .string = jsonString(root.get("latestCreatedRevision")) orelse "" } },
        .{ .name = "ready", .value = .{ .boolean = ready } },
        .{ .name = "etag", .value = .{ .string = etag } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, &outputs, null);
}

fn normalizedInputs(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, remote: std.json.ObjectMap) ProviderError!value.Value {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var normalized: std.json.ObjectMap = .empty;
    try normalized.put(arena, "project_id", .{ .string = try requiredString(node.inputs, "project_id") });
    try normalized.put(arena, "region", .{ .string = try requiredString(node.inputs, "region") });
    try normalized.put(arena, "name", .{ .string = resourceLeaf(jsonString(remote.get("name")) orelse return error.ProviderBug) });
    try normalized.put(arena, "labels", remote.get("labels") orelse .{ .object = .empty });
    try normalized.put(arena, "annotations", remote.get("annotations") orelse .{ .object = .empty });
    const outer_template = jsonObjectOptional(remote.get("template")) orelse return error.ProviderBug;
    const template = if (kind == .job) jsonObjectOptional(outer_template.get("template")) orelse return error.ProviderBug else outer_template;
    try normalized.put(arena, "containers", try normalizedContainers(context, arena, node.inputs, template));
    try normalized.put(arena, "secret_volumes", try normalizedVolumes(arena, node.inputs, template));
    try normalized.put(arena, "service_account", .{ .string = jsonString(template.get("serviceAccount")) orelse "default" });
    try normalized.put(arena, "vpc_access", try normalizedVpc(context, arena, node.inputs, template.get("vpcAccess")));
    try normalized.put(arena, "encryption_key", .{ .string = jsonString(template.get("encryptionKey")) orelse "" });
    const selector = jsonObjectOptional(template.get("nodeSelector"));
    try normalized.put(arena, "gpu_accelerator", .{ .string = if (selector) |present| jsonString(present.get("accelerator")) orelse "" else "" });
    try normalized.put(arena, "gpu_zonal_redundancy_disabled", .{ .bool = jsonBool(template.get("gpuZonalRedundancyDisabled"), false) });
    if (kind == .job) {
        try normalized.put(arena, "task_count", .{ .integer = jsonInt64(outer_template.get("taskCount")) orelse 1 });
        try normalized.put(arena, "parallelism", .{ .integer = jsonInt64(outer_template.get("parallelism")) orelse 0 });
        try normalized.put(arena, "max_retries", .{ .integer = jsonInt64(template.get("maxRetries")) orelse 3 });
        try normalized.put(arena, "timeout_seconds", .{ .integer = parseDurationSeconds(jsonString(template.get("timeout")) orelse "600s") orelse return error.ProviderBug });
        try normalized.put(arena, "execution_environment", .{ .string = jsonString(template.get("executionEnvironment")) orelse "EXECUTION_ENVIRONMENT_UNSPECIFIED" });
    } else {
        try normalized.put(arena, "description", .{ .string = jsonString(remote.get("description")) orelse "" });
        const scaling = jsonObjectOptional(remote.get("scaling"));
        try normalized.put(arena, "manual_instance_count", .{ .integer = if (scaling) |present| jsonInt64(present.get("manualInstanceCount")) orelse 1 else 1 });
        try normalized.put(arena, "revision", .{ .string = jsonString(remote.get("revision")) orelse "" });
        try normalized.put(arena, "instance_splits", try normalizedSplits(arena, remote.get("instanceSplits")));
    }
    const json = std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = normalized }, .{}) catch return error.OutOfMemory;
    defer context.allocator.free(json);
    return value.Value.parseJsonAlloc(context.allocator, json) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}

fn normalizedContainers(context: *provider_mod.OperationContext, arena: std.mem.Allocator, desired_inputs: value.Value, template: std.json.ObjectMap) ProviderError!std.json.Value {
    const remote = jsonArray(template.get("containers")) orelse return error.ProviderBug;
    const desired = try requiredList(desired_inputs, "containers");
    var result = std.json.Array.init(arena);
    for (remote.items) |item| {
        const container = jsonObject(item) orelse return error.ProviderBug;
        const name = jsonString(container.get("name")) orelse return error.ProviderBug;
        const desired_container = findByName(desired, name);
        var normalized: std.json.ObjectMap = .empty;
        try normalized.put(arena, "name", .{ .string = name });
        const remote_image = jsonString(container.get("image")) orelse return error.ProviderBug;
        try normalized.put(arena, "image", if (desired_container) |found| try preserveResolvedString(context, arena, try requiredValue(found, "image"), remote_image) else .{ .string = remote_image });
        try normalized.put(arena, "command", container.get("command") orelse emptyArray(arena));
        try normalized.put(arena, "args", container.get("args") orelse emptyArray(arena));
        const resources = jsonObjectOptional(container.get("resources"));
        const limits = if (resources) |present| jsonObjectOptional(present.get("limits")) else null;
        try normalized.put(arena, "cpu", .{ .string = if (limits) |present| jsonString(present.get("cpu")) orelse "1" else "1" });
        try normalized.put(arena, "memory", .{ .string = if (limits) |present| jsonString(present.get("memory")) orelse "512Mi" else "512Mi" });
        const desired_env = if (desired_container) |found| try requiredValue(found, "env") else value.Value{ .list = &.{} };
        try normalized.put(arena, "env", try normalizedEnv(context, arena, container.get("env"), desired_env));
        try result.append(.{ .object = normalized });
    }
    return .{ .array = result };
}

fn normalizedEnv(context: *provider_mod.OperationContext, arena: std.mem.Allocator, maybe_remote: ?std.json.Value, desired: value.Value) ProviderError!std.json.Value {
    const remote = if (maybe_remote) |present| jsonArray(present) orelse return error.ProviderBug else return emptyArray(arena);
    var result = std.json.Array.init(arena);
    for (remote.items) |item| {
        const env = jsonObject(item) orelse return error.ProviderBug;
        const name = jsonString(env.get("name")) orelse return error.ProviderBug;
        const desired_entry = findByName(try requiredListValue(desired), name);
        var normalized: std.json.ObjectMap = .empty;
        try normalized.put(arena, "name", .{ .string = name });
        if (jsonObjectOptional(env.get("valueSource"))) |source| {
            const selector = jsonObjectOptional(source.get("secretKeyRef")) orelse return error.ProviderBug;
            const secret = jsonString(selector.get("secret")) orelse return error.ProviderBug;
            const version = jsonString(selector.get("version")) orelse "latest";
            try normalized.put(arena, "secret", .{ .bool = true });
            if (desired_entry) |found| {
                const binding = try requiredValue(found, "value");
                const resolved = resolveSecret(context, binding) catch null;
                if (resolved) |reference| if (std.mem.eql(u8, reference.resource, secret) and std.mem.eql(u8, reference.version orelse "latest", version)) {
                    try normalized.put(arena, "value", try canonicalValueToJson(arena, binding));
                    try result.append(.{ .object = normalized });
                    continue;
                };
            }
            try normalized.put(arena, "value", try secretReferenceJson(arena, secret, version));
        } else {
            const remote_value = jsonString(env.get("value")) orelse "";
            try normalized.put(arena, "secret", .{ .bool = false });
            if (desired_entry) |found| {
                const binding = try requiredValue(found, "value");
                if (resolveString(context, binding) catch null) |resolved| if (std.mem.eql(u8, resolved, remote_value)) {
                    try normalized.put(arena, "value", try canonicalValueToJson(arena, binding));
                    try result.append(.{ .object = normalized });
                    continue;
                };
            }
            try normalized.put(arena, "value", .{ .string = remote_value });
        }
        try result.append(.{ .object = normalized });
    }
    return .{ .array = result };
}

fn normalizedVolumes(arena: std.mem.Allocator, desired_inputs: value.Value, template: std.json.ObjectMap) ProviderError!std.json.Value {
    const volumes = if (template.get("volumes")) |present| jsonArray(present) orelse return error.ProviderBug else return emptyArray(arena);
    const containers = if (template.get("containers")) |present| jsonArray(present) orelse return error.ProviderBug else return error.ProviderBug;
    var result = std.json.Array.init(arena);
    for (volumes.items) |item| {
        const volume = jsonObject(item) orelse return error.ProviderBug;
        const name = jsonString(volume.get("name")) orelse return error.ProviderBug;
        const secret = jsonObjectOptional(volume.get("secret")) orelse return error.ProviderBug;
        const items = jsonArray(secret.get("items")) orelse return error.ProviderBug;
        if (items.items.len == 0) return error.ProviderBug;
        const key = jsonObject(items.items[0]) orelse return error.ProviderBug;
        var container_name: []const u8 = "";
        var mount_path: ?[]const u8 = null;
        for (containers.items) |container_value| {
            const container = jsonObject(container_value) orelse return error.ProviderBug;
            const mounts = if (container.get("volumeMounts")) |present| jsonArray(present) orelse return error.ProviderBug else continue;
            for (mounts.items) |mount_value| {
                const mount = jsonObject(mount_value) orelse return error.ProviderBug;
                if (std.mem.eql(u8, jsonString(mount.get("name")) orelse "", name)) {
                    container_name = jsonString(container.get("name")) orelse return error.ProviderBug;
                    mount_path = jsonString(mount.get("mountPath")) orelse return error.ProviderBug;
                }
            }
        }
        const desired_volumes = try requiredList(desired_inputs, "secret_volumes");
        const desired_containers = try requiredList(desired_inputs, "containers");
        const desired = findByName(desired_volumes, name);
        const canonical_container = if (desired) |found| blk: {
            const explicit = try requiredString(found, "container");
            break :blk if (explicit.len == 0 and desired_containers.len == 1) "" else container_name;
        } else container_name;
        var normalized: std.json.ObjectMap = .empty;
        try normalized.put(arena, "container", .{ .string = canonical_container });
        try normalized.put(arena, "name", .{ .string = name });
        try normalized.put(arena, "path", .{ .string = jsonString(key.get("path")) orelse return error.ProviderBug });
        try normalized.put(arena, "mount_path", .{ .string = mount_path orelse return error.ProviderBug });
        try normalized.put(arena, "secret", try secretReferenceJson(arena, jsonString(secret.get("secret")) orelse return error.ProviderBug, jsonString(key.get("version")) orelse "latest"));
        try result.append(.{ .object = normalized });
    }
    return .{ .array = result };
}

fn normalizedVpc(context: *provider_mod.OperationContext, arena: std.mem.Allocator, desired_inputs: value.Value, maybe_remote: ?std.json.Value) ProviderError!std.json.Value {
    const desired = try requiredValue(desired_inputs, "vpc_access");
    if (maybe_remote == null) return emptyObject();
    const remote = jsonObject(maybe_remote.?) orelse return error.ProviderBug;
    const interfaces = jsonArray(remote.get("networkInterfaces")) orelse return error.ProviderBug;
    if (interfaces.items.len == 0) return error.ProviderBug;
    const interface = jsonObject(interfaces.items[0]) orelse return error.ProviderBug;
    var normalized: std.json.ObjectMap = .empty;
    const network = jsonString(interface.get("network")) orelse "";
    const subnetwork = jsonString(interface.get("subnetwork")) orelse "";
    try normalized.put(arena, "network", try preserveResolvedString(context, arena, try requiredValue(desired, "network"), network));
    try normalized.put(arena, "subnetwork", try preserveResolvedString(context, arena, try requiredValue(desired, "subnetwork"), subnetwork));
    try normalized.put(arena, "egress", .{ .string = jsonString(remote.get("egress")) orelse "PRIVATE_RANGES_ONLY" });
    try normalized.put(arena, "tags", interface.get("tags") orelse emptyArray(arena));
    return .{ .object = normalized };
}

fn normalizedSplits(arena: std.mem.Allocator, maybe_remote: ?std.json.Value) ProviderError!std.json.Value {
    const remote = if (maybe_remote) |present| jsonArray(present) orelse return error.ProviderBug else return emptyArray(arena);
    var result = std.json.Array.init(arena);
    for (remote.items) |item| {
        const split = jsonObject(item) orelse return error.ProviderBug;
        var normalized: std.json.ObjectMap = .empty;
        try normalized.put(arena, "allocation", .{ .string = jsonString(split.get("type")) orelse return error.ProviderBug });
        try normalized.put(arena, "percent", .{ .integer = jsonInt64(split.get("percent")) orelse return error.ProviderBug });
        try normalized.put(arena, "revision", .{ .string = jsonString(split.get("revision")) orelse "" });
        try result.append(.{ .object = normalized });
    }
    return .{ .array = result };
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try physicalIdAlloc(context.allocator, node, kind);
    defer context.allocator.free(physical);
    const outputs: []const state.StateOutput = if (kind == .job)
        &.{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "uid", .value = .{ .unknown_reason = "Cloud Run Job operation pending" } },
            .{ .name = "execution_count", .value = .{ .integer = 0 } },
            .{ .name = "latest_execution", .value = .{ .unknown_reason = "Cloud Run Job operation pending" } },
            .{ .name = "ready", .value = .{ .boolean = false } },
            .{ .name = "etag", .value = .{ .unknown_reason = "Cloud Run Job operation pending" } },
        }
    else
        &.{
            .{ .name = "name", .value = .{ .string = physical } },
            .{ .name = "uid", .value = .{ .unknown_reason = "Cloud Run WorkerPool operation pending" } },
            .{ .name = "latest_ready_revision", .value = .{ .unknown_reason = "Cloud Run WorkerPool operation pending" } },
            .{ .name = "latest_created_revision", .value = .{ .unknown_reason = "Cloud Run WorkerPool operation pending" } },
            .{ .name = "ready", .value = .{ .boolean = false } },
            .{ .name = "etag", .value = .{ .unknown_reason = "Cloud Run WorkerPool operation pending" } },
        };
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, outputs, handle);
    result.completed = false;
    return result;
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/{s}/{s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "region"),
        if (kind == .job) "jobs" else "workerPools",
        try requiredString(node.inputs, "name"),
    }) catch error.OutOfMemory;
}

fn rpcPathAlloc(context: *provider_mod.OperationContext, method: rpc.Method, path_parameters: []const rpc.Parameter, query_parameters: []const rpc.Parameter) ProviderError![]u8 {
    return rpc.restPathAlloc(context.allocator, method, path_parameters, query_parameters) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}

fn conditionSucceeded(maybe_condition: ?std.json.Value) bool {
    const condition = if (maybe_condition) |present| jsonObject(present) orelse return false else return false;
    return std.mem.eql(u8, jsonString(condition.get("state")) orelse "", "CONDITION_SUCCEEDED");
}

fn parseDurationSeconds(text: []const u8) ?i64 {
    if (!std.mem.endsWith(u8, text, "s") or text.len < 2) return null;
    return std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch null;
}

fn resourceLeaf(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, '/')) |index| name[index + 1 ..] else name;
}

fn findByName(items: []const value.Value, name: []const u8) ?value.Value {
    for (items) |item| if (std.mem.eql(u8, requiredString(item, "name") catch continue, name)) return item;
    return null;
}

fn preserveResolvedString(context: *provider_mod.OperationContext, arena: std.mem.Allocator, desired: value.Value, remote: []const u8) ProviderError!std.json.Value {
    if (std.mem.eql(u8, try resolveString(context, desired), remote)) return canonicalValueToJson(arena, desired);
    return .{ .string = remote };
}

fn canonicalValueToJson(arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    const json = input.canonicalJsonAlloc(arena) catch |err| switch (err) {
        error.DuplicateField => return error.InvalidConfiguration,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.ProviderBug;
}

fn secretReferenceJson(arena: std.mem.Allocator, secret: []const u8, version: []const u8) ProviderError!std.json.Value {
    var reference: std.json.ObjectMap = .empty;
    try reference.put(arena, "provider", .{ .string = "gcp-secret-manager" });
    try reference.put(arena, "resource", .{ .string = secret });
    try reference.put(arena, "version", .{ .string = version });
    var wrapper: std.json.ObjectMap = .empty;
    try wrapper.put(arena, "$secret", .{ .object = reference });
    return .{ .object = wrapper };
}

fn stringListJson(arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var result = std.json.Array.init(arena);
    for (try requiredListValue(input)) |item| switch (item) {
        .string => |text| try result.append(.{ .string = text }),
        else => return error.InvalidConfiguration,
    };
    return .{ .array = result };
}

fn plainValueToJson(arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    return switch (input) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |boolean| .{ .bool = boolean },
        .list => |items| list: {
            var array = std.json.Array.init(arena);
            for (items) |item| try array.append(try plainValueToJson(arena, item));
            break :list .{ .array = array };
        },
        .object => |fields| object: {
            var map: std.json.ObjectMap = .empty;
            for (fields) |field| try map.put(arena, field.name, try plainValueToJson(arena, field.value));
            break :object .{ .object = map };
        },
        .secret_ref, .output_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn resolveSecret(context: *provider_mod.OperationContext, input: value.Value) ProviderError!value.SecretReference {
    const reference = switch (input) {
        .secret_ref => |present| present,
        .output_ref => |output_reference| try context.resolveOutputSecret(output_reference),
        else => return error.InvalidConfiguration,
    };
    if (!std.mem.eql(u8, reference.provider, "gcp-secret-manager") or reference.resource.len == 0 or reference.field != null) return error.InvalidConfiguration;
    return reference;
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = try requiredObjectValue(input);
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
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
fn requiredBool(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |boolean| boolean,
        else => error.InvalidConfiguration,
    };
}
fn requiredSecret(input: value.Value, name: []const u8) ProviderError!value.SecretReference {
    return switch (try requiredValue(input, name)) {
        .secret_ref => |reference| reference,
        else => error.InvalidConfiguration,
    };
}
fn requiredList(input: value.Value, name: []const u8) ProviderError![]const value.Value {
    return requiredListValue(try requiredValue(input, name));
}
fn requiredListValue(input: value.Value) ProviderError![]const value.Value {
    return switch (input) {
        .list => |items| items,
        else => error.InvalidConfiguration,
    };
}
fn requiredObjectValue(input: value.Value) ProviderError![]const value.Field {
    return switch (input) {
        .object => |fields| fields,
        else => error.InvalidConfiguration,
    };
}
fn inputString(input: value.Value, name: []const u8) ?[]const u8 {
    return requiredString(input, name) catch null;
}
fn outputString(result: *const provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .string => |text| text,
        else => null,
    };
    return null;
}
fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}
fn jsonObjectOptional(input: ?std.json.Value) ?std.json.ObjectMap {
    return if (input) |present| jsonObject(present) else null;
}
fn jsonArray(input: ?std.json.Value) ?std.json.Array {
    return if (input) |present| switch (present) {
        .array => |array| array,
        else => null,
    } else null;
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
fn emptyArray(arena: std.mem.Allocator) std.json.Value {
    return .{ .array = std.json.Array.init(arena) };
}
fn emptyObject() std.json.Value {
    return .{ .object = .empty };
}
